import XCTest
@testable import GenioCore

/// A scripted WebSocket: records what the client sends, delivers what the
/// test pushes, fails when told to.
final class MockConnection: WebSocketConnection, @unchecked Sendable {
  private let lock = NSLock()
  private var _sent: [String] = []
  private var _closeInfo: (code: Int, reason: String)?
  private var _closed = false
  private let stream: AsyncThrowingStream<WebSocketMessage, Error>
  private let feed: AsyncThrowingStream<WebSocketMessage, Error>.Continuation
  private var iterator: AsyncThrowingStream<WebSocketMessage, Error>.AsyncIterator

  init() {
    var feed: AsyncThrowingStream<WebSocketMessage, Error>.Continuation!
    stream = AsyncThrowingStream { feed = $0 }
    self.feed = feed
    iterator = stream.makeAsyncIterator()
  }

  var sent: [String] { lock.withLock { _sent } }
  var closed: Bool { lock.withLock { _closed } }

  /// Sent messages decoded, with their single top-level key.
  var sentKinds: [String] { sent.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?.keys.first } }

  func setup() -> [String: Any]? {
    guard let first = sent.first,
          let root = try? JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any]
    else { return nil }
    return root["setup"] as? [String: Any]
  }

  func push(_ json: String) { feed.yield(.text(json)) }

  func drop(code: Int? = nil, reason: String = "") {
    lock.withLock { if let code { _closeInfo = (code, reason) } }
    feed.finish(throwing: URLError(.networkConnectionLost))
  }

  func send(_ text: String) async throws {
    lock.withLock { _sent.append(text) }
  }

  func receive() async throws -> WebSocketMessage {
    guard let message = try await iterator.next() else { throw URLError(.networkConnectionLost) }
    return message
  }

  func close() {
    lock.withLock { _closed = true }
    feed.finish()
  }

  var closeInfo: (code: Int, reason: String)? { lock.withLock { _closeInfo } }
}

final class MockConnector: WebSocketConnector, @unchecked Sendable {
  private let lock = NSLock()
  private var _connections: [MockConnection] = []
  var connections: [MockConnection] { lock.withLock { _connections } }

  func connect(to url: URL) -> WebSocketConnection {
    let connection = MockConnection()
    lock.withLock { _connections.append(connection) }
    return connection
  }
}

actor EventLog {
  private(set) var events: [GeminiLiveSession.Event] = []
  func append(_ event: GeminiLiveSession.Event) { events.append(event) }

  var states: [GeminiLiveSession.State] {
    events.compactMap { if case .state(let state) = $0 { return state } else { return nil } }
  }
  var toolCalls: [[FunctionCall]] {
    events.compactMap { if case .server(.toolCall(let calls)) = $0 { return calls } else { return nil } }
  }
  var resumedCount: Int { events.filter { if case .resumed = $0 { return true } else { return false } }.count }
  var contextLostCount: Int { events.filter { if case .contextLost = $0 { return true } else { return false } }.count }
}

final class GeminiLiveSessionTests: XCTestCase {
  private var connector: MockConnector!
  private var session: GeminiLiveSession!
  private var log: EventLog!
  private var listener: Task<Void, Never>?

  override func setUp() async throws {
    connector = MockConnector()
    log = EventLog()
    var options = GeminiLiveSession.Options()
    options.setupTimeout = 1000  // never, at the test's time scale
    options.maxAttempts = 3
    session = GeminiLiveSession(
      apiKey: "test-key", connector: connector, options: options,
      sleep: { seconds in try await Task.sleep(nanoseconds: UInt64(seconds * 10_000_000)) },  // 100x faster
      makeSetup: { handle in
        LiveSetup(model: "gemini-3.8-live", voiceName: "Kore", systemInstruction: "Sei Genio.",
                  tools: [], resumptionHandle: handle)
      })
    let session = session!, log = log!
    listener = Task { for await event in session.events { await log.append(event) } }
  }

  override func tearDown() async throws {
    await session.stop()
    listener?.cancel()
  }

  /// Waits (up to 2 s) for `condition`.
  private func eventually(_ what: String, _ condition: @escaping () async -> Bool) async {
    for _ in 0..<400 {
      if await condition() { return }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("timed out waiting for \(what)")
  }

  private func connection(_ index: Int) async -> MockConnection {
    await eventually("connection \(index)") { self.connector.connections.count > index && !self.connector.connections[index].sent.isEmpty }
    return connector.connections[index]
  }

  private func ready(_ connection: MockConnection) async {
    connection.push(#"{"setupComplete": {}}"#)
    await eventually("ready") { await self.session.isReady }
  }

  func testSetupComesFirstAndAudioWaitsForReady() async {
    await session.start()
    let first = await connection(0)
    XCTAssertEqual(first.sentKinds, ["setup"])
    XCTAssertEqual(first.setup()?["model"] as? String, "models/gemini-3.8-live")
    await session.sendAudio(Data([1, 2]))
    XCTAssertEqual(first.sentKinds, ["setup"], "audio before setupComplete is dropped")
    await ready(first)
    await session.sendAudio(Data([1, 2]))
    await session.sendVideo(Data([0xFF]))
    XCTAssertEqual(first.sentKinds, ["setup", "realtimeInput", "realtimeInput"])
    let states = await log.states
    XCTAssertEqual(states, [.connecting, .ready])
  }

  func testReconnectsWithTheResumptionHandle() async {
    await session.start()
    let first = await connection(0)
    await ready(first)
    first.push(#"{"sessionResumptionUpdate": {"newHandle": "h-1", "resumable": true}}"#)
    await eventually("handle") { await self.session.resumptionHandle == "h-1" }
    first.drop()

    let second = await connection(1)
    XCTAssertEqual((second.setup()?["sessionResumption"] as? [String: Any])?["handle"] as? String, "h-1")
    await ready(second)
    await eventually("resumed event") { await self.log.resumedCount == 1 }
    let lost = await log.contextLostCount
    XCTAssertEqual(lost, 0)
  }

  func testGoAwayMovesToANewConnectionAtOnce() async {
    await session.start()
    let first = await connection(0)
    await ready(first)
    first.push(#"{"sessionResumptionUpdate": {"newHandle": "h-9", "resumable": true}}"#)
    first.push(#"{"goAway": {"timeLeft": "30s"}}"#)
    let second = await connection(1)
    XCTAssertTrue(first.closed)
    XCTAssertEqual((second.setup()?["sessionResumption"] as? [String: Any])?["handle"] as? String, "h-9")
  }

  func testWithoutAHandleAReconnectLosesContext() async {
    await session.start()
    let first = await connection(0)
    await ready(first)
    first.drop()
    let second = await connection(1)
    XCTAssertEqual((second.setup()?["sessionResumption"] as? [String: Any])?.isEmpty, true)
    await ready(second)
    await eventually("contextLost") { await self.log.contextLostCount == 1 }
  }

  func testToolCallsAreDeliveredAndAnsweredOnce() async {
    await session.start()
    let first = await connection(0)
    await ready(first)
    let call = #"{"toolCall": {"functionCalls": [{"id": "c1", "name": "get_task_state", "args": {}}]}}"#
    first.push(call)
    first.push(call)  // a duplicate (for example re-sent after a hiccup)
    first.push(#"{"toolCall": {"functionCalls": [{"id": "c2", "name": "get_task_state", "args": {}}]}}"#)
    await eventually("two calls") { await self.log.toolCalls.count == 2 }
    let ids = await log.toolCalls.flatMap { $0.map(\.id) }
    XCTAssertEqual(ids, ["c1", "c2"])

    first.push(#"{"toolCallCancellation": {"ids": ["c2"]}}"#)
    try? await Task.sleep(nanoseconds: 50_000_000)
    let response = FunctionResponse(id: "c1", name: "get_task_state", response: .object([:]))
    await session.respond([response])
    await session.respond([response])
    await session.respond([FunctionResponse(id: "c2", name: "get_task_state", response: .object([:]))])
    XCTAssertEqual(first.sentKinds.filter { $0 == "toolResponse" }.count, 1, "c1 once, c2 cancelled")
  }

  func testInvalidKeyIsNotRetried() async {
    await session.start()
    let first = await connection(0)
    first.drop(code: 1008, reason: "API key not valid. Please pass a valid API key.")
    await eventually("failed") {
      if case .failed = await self.session.currentState { return true }
      return false
    }
    try? await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(connector.connections.count, 1)
  }

  func testGivesUpAfterTooManyFailures() async {
    await session.start()
    for index in 0...3 {
      let connection = await connection(index)
      connection.drop()
    }
    await eventually("failed") {
      if case .failed = await self.session.currentState { return true }
      return false
    }
    XCTAssertEqual(connector.connections.count, 4, "first try + 3 retries")
  }

  func testRepeatedResumeFailuresStartFresh() async {
    await session.start()
    let first = await connection(0)
    await ready(first)
    first.push(#"{"sessionResumptionUpdate": {"newHandle": "old", "resumable": true}}"#)
    await eventually("handle") { await self.session.resumptionHandle == "old" }
    first.drop()
    let second = await connection(1)  // tries the handle
    second.drop()
    let third = await connection(2)  // tries it again
    third.drop()
    let fourth = await connection(3)  // gives the handle up
    XCTAssertEqual((fourth.setup()?["sessionResumption"] as? [String: Any])?.isEmpty, true)
    await ready(fourth)
    await eventually("contextLost") { await self.log.contextLostCount == 1 }
  }

  func testStopClosesAndStaysStopped() async {
    await session.start()
    let first = await connection(0)
    await ready(first)
    await session.stop()
    XCTAssertTrue(first.closed)
    try? await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(connector.connections.count, 1)
    let state = await session.currentState
    XCTAssertEqual(state, .stopped)
  }
}
