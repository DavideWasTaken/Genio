import Foundation
import GenioCore

/// The Gemini Live conversation: the glasses' microphone to Gemini, Gemini's
/// voice to the glasses, sampled camera frames in the same session, and
/// Gemini's function calls routed to TaskEngine through TaskTools.
///
/// TaskEngine stays the source of truth. The conversation's own memory
/// (kept by Gemini, carried across reconnects by session resumption) is a
/// convenience: after a reconnect that loses it, the task state is sent
/// again from the engine.
@MainActor
final class LiveConversationEngine: ObservableObject {
  enum Status: Equatable {
    case off
    case connecting
    case live
    case reconnecting(Int)
    case failed(String)
  }

  struct Settings: Equatable {
    var apiKey: String
    var model: String
    var voice: String
    var framesPerSecond: Double
    var languageName: String
  }

  struct Metrics: Equatable {
    var framesSent = 0
    var framesDropped = 0
    var frameLatency: TimeInterval = 0
    var totalTokens = 0
    var connectedSeconds: TimeInterval = 0
  }

  static let defaultModel = "gemini-3.8-live"
  static let defaultVoice = "Kore"
  /// Prebuilt voices of the Live native-audio models.
  static let voices = [
    "Kore", "Aoede", "Leda", "Zephyr", "Autonoe", "Despina", "Erinome", "Laomedeia", "Pulcherrima", "Sulafat",
    "Puck", "Charon", "Fenrir", "Orus", "Enceladus", "Iapetus", "Umbriel", "Algieba", "Algenib", "Rasalgethi",
    "Achernar", "Alnilam", "Schedar", "Gacrux", "Achird", "Zubenelgenubi", "Vindemiatrix", "Sadachbia", "Sadaltager", "Callirrhoe",
  ]

  @Published private(set) var status: Status = .off
  /// What the user said in the current turn (input transcription).
  @Published private(set) var userTranscript = ""
  /// What Genio is saying (output transcription).
  @Published private(set) var genioTranscript = ""
  @Published private(set) var metrics = Metrics()
  @Published private(set) var isModelSpeaking = false

  var onLog: ((String) -> Void)?

  private let audio: AudioManager
  private let call: CallSession
  private let glasses: GlassesManager
  private let engine: TaskEngine
  private let tools: TaskTools
  private var session: GeminiLiveSession?
  private var eventTask: Task<Void, Never>?
  private var micTask: Task<Void, Never>?
  private var videoTask: Task<Void, Never>?
  private var micContinuation: AsyncStream<Data>.Continuation?
  private var pacer = FramePacer()
  private var connectedSince: Date?
  /// User speech with arrival times, for checking quoted user words.
  private var heard: [(Date, String)] = []
  /// Set while a function call runs: step changes made by Gemini's own call
  /// are announced through the call's result, not again as an app event.
  private var inToolCall = false
  /// The task revision Gemini last saw (to resync after a reconnect).
  private var syncedRevision: Int?
  /// Bumped by stop(): a start() still waiting (microphone permission,
  /// audio setup) sees it changed and gives up.
  private var startGeneration = 0
  /// "Genio stop" was heard in this session (acted on once).
  private var stopHeard = false
  /// Language of the current session, for the greeting.
  private var languageName = "Italian"
  /// Genio finished its turn: its next words start a new transcript.
  private var genioTurnEnded = true
  /// The user's words were answered: their next words start a new one.
  private var userTurnEnded = true
  /// The last start failed because of the microphone (not the network).
  private(set) var lastFailureWasAudio = false

  init(audio: AudioManager, call: CallSession, glasses: GlassesManager, engine: TaskEngine) {
    self.audio = audio
    self.call = call
    self.glasses = glasses
    self.engine = engine
    tools = TaskTools(engine: engine)
    tools.recentUserSpeech = { [weak self] in self?.recentSpeech() ?? "" }
  }

  var isActive: Bool { session != nil }
  /// The user asked to pause (pause_guidance): the controller switches GENIO off.
  var onPauseRequested: (() -> Void)? {
    get { tools.onPauseRequested }
    set { tools.onPauseRequested = newValue }
  }

  // MARK: - Lifecycle

  func start(_ settings: Settings) async {
    guard session == nil else { return }
    guard !settings.apiKey.isEmpty else {
      status = .failed(String(localized: "The Gemini API key is missing (Settings)."))
      return
    }
    startGeneration += 1
    let myStart = startGeneration
    status = .connecting
    stopHeard = false
    languageName = settings.languageName
    let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(64))
    micContinuation = continuation
    audio.onMicrophonePCM = { pcm in continuation.yield(pcm) }
    lastFailureWasAudio = false
    // The microphone permission must be asked with the app on screen; a
    // call (CallKit) then lets the microphone start even from the
    // background. If iOS refuses the call, try without (works on screen).
    var audioReady = false
    if await audio.microphoneAllowed() {
      audio.releaseForCall()
      let inCall = await call.start()
      guard myStart == startGeneration else { return }  // stopped meanwhile
      audioReady = await audio.configureLive(activatedByCall: inCall)
    }
    guard myStart == startGeneration else { return }  // stopped meanwhile
    guard audioReady else {
      lastFailureWasAudio = true
      status = .failed(audio.lastError ?? String(localized: "The microphone could not start."))
      cleanUp()
      return
    }

    let engine = engine
    let newSession = GeminiLiveSession(apiKey: settings.apiKey) { handle in
      await MainActor.run {
        LiveSetup(
          model: settings.model.isEmpty ? Self.defaultModel : settings.model,
          voiceName: settings.voice.isEmpty ? nil : settings.voice,
          systemInstruction: LiveInstructions.system(language: settings.languageName, snapshot: engine.snapshot()),
          tools: TaskTools.declarations,
          resumptionHandle: handle)
      }
    }
    session = newSession
    pacer = FramePacer(framesPerSecond: settings.framesPerSecond)
    metrics = Metrics()
    syncedRevision = engine.task?.revision

    eventTask = Task { [weak self] in
      for await event in newSession.events {
        guard let self else { return }
        await self.handle(event)
      }
    }
    // One consumer, so audio chunks reach the socket in order.
    micTask = Task {
      for await pcm in stream {
        await newSession.sendAudio(pcm)
      }
    }
    videoTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(250))
        await self?.videoTick()
      }
    }
    await newSession.start()
  }

  func stop() {
    startGeneration += 1
    if let session {
      Task { await session.stop() }
      onLog?("Gemini Live: off")
    }
    cleanUp()
    status = .off
  }

  // MARK: - App events for the conversation

  /// A task change made by the app (the coach confirmed a step): Gemini
  /// announces it. Changes Gemini made itself are skipped.
  func taskEventOccurred(_ event: TaskEvent) {
    guard !inToolCall, let session, let text = LiveInstructions.stepEvent(event) else { return }
    syncedRevision = engine.task?.revision
    Task { await session.sendText(text) }
  }

  /// A remark from the separate coach, to be said by Gemini.
  func relayRemark(_ remark: String, kind: RemarkKind) {
    guard let session else { return }
    let tone = kind == .hazard ? "Warn the user now" : "Tell the user"
    Task { await session.sendText("[Genio] The vision coach noticed: \"\(remark)\". \(tone), in one short cautious sentence, in your words.") }
  }

  // MARK: - Session events

  private func handle(_ event: GeminiLiveSession.Event) async {
    switch event {
    case .state(let state):
      apply(state)
    case .log(let line):
      onLog?("Gemini Live: \(line)")
    case .resumed:
      onLog?("Gemini Live: resumed the conversation")
      if engine.task?.revision != syncedRevision { await resync() }
    case .contextLost:
      onLog?("Gemini Live: new conversation, sending the task state")
      await resync()
    case .server(let server):
      await handle(server)
    }
  }

  private func handle(_ event: LiveServerEvent) async {
    switch event {
    case .audio(let pcm):
      audio.playVoice(pcm24k: pcm)
      isModelSpeaking = true
    case .interrupted:
      // The user started talking: stop Genio's voice at once.
      audio.flushVoice()
      isModelSpeaking = false
    case .turnComplete, .generationComplete:
      isModelSpeaking = audio.isPlayingVoice
      if event == .turnComplete, !genioTurnEnded {
        genioTurnEnded = true
        let line = genioTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.isEmpty { onLog?("Genio: \(line)") }
      }
    case .inputTranscript(let text):
      // Pieces keep their own spacing ("Ciao", " come", " stai?"): joined
      // as they come, trimmed only for display.
      if userTurnEnded {
        userTranscript = ""
        userTurnEnded = false
      }
      userTranscript += text
      heard.append((Date(), text))
      // "Genio stop" switches off directly, whatever the model does.
      if !stopHeard, VoiceStop.matches(userTranscript) {
        stopHeard = true
        onLog?("Heard \"\(userTranscript.trimmingCharacters(in: .whitespaces))\": switching off")
        onPauseRequested?()
      }
    case .outputTranscript(let text):
      if !userTurnEnded {
        userTurnEnded = true
        let line = userTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.isEmpty { onLog?("Heard: \(line)") }
      }
      if genioTurnEnded {
        genioTranscript = ""
        genioTurnEnded = false
      }
      genioTranscript += text
    case .toolCall(let calls):
      var responses: [FunctionResponse] = []
      inToolCall = true
      for call in calls {
        let response = tools.handle(call)
        onLog?("Tool \(call.name) → \(response.response["status"]?.stringValue ?? "?")")
        responses.append(response)
      }
      inToolCall = false
      syncedRevision = engine.task?.revision
      await session?.respond(responses)
    case .toolCallCancellation(let ids):
      onLog?("Gemini Live: calls cancelled \(ids.joined(separator: ", "))")
    case .usage(let usage):
      metrics.totalTokens = max(metrics.totalTokens, usage.totalTokens)
    case .serverError(let message):
      onLog?("Gemini Live error: \(message)")
    case .goAway, .setupComplete, .resumptionUpdate, .text:
      break
    }
  }

  private func apply(_ state: GeminiLiveSession.State) {
    switch state {
    case .idle, .connecting:
      status = .connecting
    case .ready:
      if status != .live { onLog?("Gemini Live: connected") }
      status = .live
      if connectedSince == nil {
        // First connection of this session: the fixed greeting, once.
        connectedSince = Date()
        let text = LiveInstructions.greeting(language: languageName)
        if let session { Task { await session.sendText(text) } }
      }
    case .reconnecting(let attempt):
      status = .reconnecting(attempt)
      audio.flushVoice()
    case .stopped:
      status = .off
    case .failed(let reason):
      status = .failed(reason)
      onLog?("Gemini Live: \(reason)")
      cleanUp()
    }
  }

  /// Tells Gemini where the task stands (after a reconnect).
  private func resync() async {
    syncedRevision = engine.task?.revision
    await session?.sendText(LiveInstructions.contextRecovery(snapshot: engine.snapshot()))
  }

  // MARK: - Video

  private func videoTick() async {
    // Runs in the background too (phone in a pocket): iOS keeps the app
    // alive while the microphone is open.
    guard let session, status == .live else { return }
    if let since = connectedSince { metrics.connectedSeconds = Date().timeIntervalSince(since) }
    guard pacer.decide(frameTime: glasses.latestFrameTime, now: Date()) == .send else {
      syncMetrics(session)
      return
    }
    guard case let (jpeg, frameTime)? = await glasses.latestJPEGInBackground(maxAge: pacer.maxFrameAge, maxDimension: 768) else {
      pacer.finished(frameTime: Date(), now: Date(), sent: false)
      return
    }
    let sent = await session.sendVideo(jpeg)
    pacer.finished(frameTime: frameTime, now: Date(), sent: sent)
    syncMetrics(session)
  }

  private func syncMetrics(_ session: GeminiLiveSession) {
    metrics.framesSent = pacer.metrics.sent
    metrics.framesDropped = pacer.metrics.droppedStale + pacer.metrics.droppedBusy + pacer.metrics.failed
    metrics.frameLatency = pacer.metrics.averageLatency
  }

  // MARK: - Helpers

  private func recentSpeech() -> String {
    let cutoff = Date().addingTimeInterval(-20)
    heard.removeAll { $0.0 < cutoff }
    return heard.map(\.1).joined(separator: " ")
  }

  private func cleanUp() {
    eventTask?.cancel()
    micTask?.cancel()
    videoTask?.cancel()
    micContinuation?.finish()
    eventTask = nil
    micTask = nil
    videoTask = nil
    micContinuation = nil
    audio.onMicrophonePCM = nil
    audio.flushVoice()
    call.end()
    session = nil
    connectedSince = nil
    isModelSpeaking = false
    userTranscript = ""
    genioTranscript = ""
    userTurnEnded = true
    genioTurnEnded = true
  }
}
