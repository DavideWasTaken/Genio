import Foundation

/// A Gemini Live conversation that survives the network: one WebSocket at a
/// time, replaced when the server sends goAway (connections last about ten
/// minutes), when it drops, or when setup times out.
///
///  - Session resumption: every reconnect sends the last resumable handle,
///    so the model keeps the conversation. If resuming keeps failing, or the
///    handle is too old (2 h), it starts fresh and emits `.contextLost` so
///    the caller can tell the model where the task stands.
///  - Context compression is always on (an audio+video session would
///    otherwise end after 2 minutes).
///  - Backoff: 0.5 s, 1 s, 2 s… up to `maxBackoff`, with jitter; gives up
///    after `maxAttempts` failures in a row, or at once on an invalid key.
///  - Tool calls are delivered once per id, cancelled calls are never
///    answered, and each call is answered at most once.
public actor GeminiLiveSession {
  public enum State: Equatable, Sendable {
    case idle
    case connecting
    case ready
    case reconnecting(attempt: Int)
    case stopped
    case failed(String)
  }

  public enum Event: Sendable {
    case state(State)
    case server(LiveServerEvent)
    /// Reconnected and the server kept the conversation.
    case resumed
    /// Reconnected without the old conversation: the model knows only the
    /// system instruction (which carries the task state).
    case contextLost
    case log(String)
  }

  public struct Options: Sendable {
    public var maxAttempts = 8
    public var baseBackoff: TimeInterval = 0.5
    public var maxBackoff: TimeInterval = 20
    public var setupTimeout: TimeInterval = 12
    /// Failed resumptions in a row before starting a fresh session.
    public var resumeFailuresBeforeFresh = 2
    /// Audio chunks allowed in flight before new ones are dropped.
    public var maxPendingSends = 24

    public init() {}
  }

  public nonisolated let events: AsyncStream<Event>
  private let continuation: AsyncStream<Event>.Continuation

  private let apiKey: String
  private let connector: WebSocketConnector
  private let options: Options
  /// The setup for a connection, given the resumption handle (if any). Asked
  /// on every connect so the system instruction carries the current task.
  private let makeSetup: @Sendable (String?) async -> LiveSetup
  private let sleep: @Sendable (TimeInterval) async throws -> Void

  private var connection: WebSocketConnection?
  private var connectionID = 0
  private var state: State = .idle
  private var ready = false
  private var running = false
  private var resumeHandle: String?
  private var failures = 0
  private var resumeFailures = 0
  private var everConnected = false
  private var connectedWithHandle = false
  private var pendingSends = 0
  private var seenCalls: Set<String> = []
  private var answeredCalls: Set<String> = []
  private var cancelledCalls: Set<String> = []
  public private(set) var droppedAudioChunks = 0

  public init(
    apiKey: String,
    connector: WebSocketConnector = URLSessionWebSocketConnector(),
    options: Options = Options(),
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
    makeSetup: @escaping @Sendable (String?) async -> LiveSetup
  ) {
    self.apiKey = apiKey
    self.connector = connector
    self.options = options
    self.sleep = sleep
    self.makeSetup = makeSetup
    var continuation: AsyncStream<Event>.Continuation!
    events = AsyncStream(bufferingPolicy: .bufferingNewest(512)) { continuation = $0 }
    self.continuation = continuation
  }

  public var currentState: State { state }
  public var isReady: Bool { ready }
  public var resumptionHandle: String? { resumeHandle }

  // MARK: - Lifecycle

  public func start() async {
    guard !running else { return }
    running = true
    failures = 0
    await connect()
  }

  public func stop() {
    running = false
    ready = false
    connectionID += 1
    connection?.close()
    connection = nil
    set(.stopped)
  }

  /// Forgets the conversation: the next connect starts fresh.
  public func forgetConversation() {
    resumeHandle = nil
  }

  // MARK: - Sending

  /// 16 kHz 16-bit mono PCM. Dropped while not connected (nothing to say it
  /// to), or when too much is already queued (a slow network must not build
  /// up seconds of stale audio).
  public func sendAudio(_ pcm: Data) async {
    guard ready else { return }
    guard pendingSends < options.maxPendingSends else {
      droppedAudioChunks += 1
      return
    }
    await send(LiveClientMessage.audio(pcm))
  }

  /// Returns false if the frame was not sent (not connected, or failed).
  @discardableResult
  public func sendVideo(_ jpeg: Data) async -> Bool {
    guard ready else { return false }
    return await send(LiveClientMessage.video(jpeg: jpeg))
  }

  public func sendText(_ text: String) async {
    guard ready else { return }
    await send(LiveClientMessage.text(text))
  }

  public func sendClientText(_ text: String, turnComplete: Bool) async {
    guard ready else { return }
    await send(LiveClientMessage.clientText(text, turnComplete: turnComplete))
  }

  /// Tells the server the microphone paused (so it can close the turn).
  public func sendAudioStreamEnd() async {
    guard ready else { return }
    await send(LiveClientMessage.audioStreamEnd())
  }

  /// Answers tool calls, each at most once, never a cancelled one.
  public func respond(_ responses: [FunctionResponse]) async {
    let fresh = responses.filter { !answeredCalls.contains($0.id) && !cancelledCalls.contains($0.id) }
    guard !fresh.isEmpty, ready else { return }
    for response in fresh { answeredCalls.insert(response.id) }
    await send(LiveClientMessage.toolResponse(fresh))
  }

  // MARK: - Connection

  private func connect() async {
    guard running else { return }
    connectionID += 1
    let id = connectionID
    ready = false
    set(everConnected ? .reconnecting(attempt: failures) : .connecting)
    guard let url = LiveEndpoint.url(apiKey: apiKey) else {
      fail("Invalid endpoint")
      return
    }
    let socket = connector.connect(to: url)
    connection = socket
    connectedWithHandle = resumeHandle != nil
    let setup = await makeSetup(resumeHandle)
    guard running, id == connectionID else {
      socket.close()
      return
    }
    do {
      try await socket.send(LiveClientMessage.encode(LiveClientMessage.setup(setup)))
    } catch {
      await dropped(id, error: error)
      return
    }
    Task { await self.receiveLoop(socket, id: id) }
    Task {
      try? await self.sleep(self.options.setupTimeout)
      await self.setupTimedOut(id)
    }
  }

  private func receiveLoop(_ socket: WebSocketConnection, id: Int) async {
    while id == connectionID {
      do {
        let message = try await socket.receive()
        guard id == connectionID else { return }
        for event in LiveServerMessage.events(from: message.payload) {
          await handle(event, connection: id)
          guard id == connectionID else { return }
        }
      } catch {
        await dropped(id, error: error, closeInfo: socket.closeInfo)
        return
      }
    }
  }

  private func handle(_ event: LiveServerEvent, connection id: Int) async {
    switch event {
    case .setupComplete:
      ready = true
      failures = 0
      if everConnected {
        if connectedWithHandle {
          resumeFailures = 0
          continuation.yield(.resumed)
        } else {
          continuation.yield(.contextLost)
        }
      }
      everConnected = true
      set(.ready)
    case .resumptionUpdate(let newHandle, let resumable):
      if resumable, let newHandle { resumeHandle = newHandle }
    case .goAway(let timeLeft):
      log("goAway (\(timeLeft.map { String(format: "%.0f s", $0) } ?? "?") left): reconnecting with the session handle")
      continuation.yield(.server(event))
      // Move to a new connection now, while the handle is fresh.
      connection?.close()
      connectionID += 1
      ready = false
      await connect()
      return
    case .toolCall(let calls):
      let fresh = calls.filter { seenCalls.insert($0.id).inserted }
      if !fresh.isEmpty { continuation.yield(.server(.toolCall(fresh))) }
      return
    case .toolCallCancellation(let ids):
      cancelledCalls.formUnion(ids)
    default:
      break
    }
    continuation.yield(.server(event))
  }

  private func setupTimedOut(_ id: Int) async {
    guard id == connectionID, !ready, running else { return }
    log("Setup timed out")
    connection?.close()
    await dropped(id, error: URLError(.timedOut))
  }

  /// The connection `id` ended. Reconnects, unless it was replaced, the
  /// session was stopped, the key is invalid, or too many attempts failed.
  private func dropped(_ id: Int, error: Error, closeInfo: (code: Int, reason: String)? = nil) async {
    guard id == connectionID, running else { return }
    ready = false
    connection = nil
    if let closeInfo, Self.isFatal(closeInfo) {
      fail("Closed by the server (\(closeInfo.code)): \(closeInfo.reason)")
      return
    }
    failures += 1
    if connectedWithHandle {
      resumeFailures += 1
      if resumeFailures >= options.resumeFailuresBeforeFresh {
        log("Resuming failed \(resumeFailures) times: starting a fresh session")
        resumeHandle = nil
        resumeFailures = 0
      }
    }
    guard failures <= options.maxAttempts else {
      fail("Connection lost: \(closeInfo?.reason.isEmpty == false ? closeInfo!.reason : error.localizedDescription)")
      return
    }
    let delay = min(options.maxBackoff, options.baseBackoff * pow(2, Double(failures - 1))) * Double.random(in: 0.8...1.2)
    log(String(format: "Connection dropped (%@): retry %d in %.1f s", closeInfo.map { "\($0.code) \($0.reason)" } ?? error.localizedDescription, failures, delay))
    set(.reconnecting(attempt: failures))
    try? await sleep(delay)
    guard id == connectionID, running else { return }
    await connect()
  }

  /// Policy violation (bad key, no access to the model) or a malformed
  /// message: retrying cannot help.
  static func isFatal(_ info: (code: Int, reason: String)) -> Bool {
    let reason = info.reason.lowercased()
    return info.code == 1008 || info.code == 1007 || reason.contains("api key") || reason.contains("permission")
  }

  @discardableResult
  private func send(_ message: [String: Any]) async -> Bool {
    guard let connection else { return false }
    pendingSends += 1
    defer { pendingSends -= 1 }
    do {
      try await connection.send(LiveClientMessage.encode(message))
      return true
    } catch {
      return false
    }
  }

  private func fail(_ reason: String) {
    running = false
    ready = false
    connectionID += 1
    connection?.close()
    connection = nil
    set(.failed(reason))
  }

  private func set(_ newState: State) {
    guard newState != state else { return }
    state = newState
    continuation.yield(.state(newState))
  }

  private func log(_ line: String) {
    continuation.yield(.log(line))
  }
}
