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
  private var userTranscript = ""
  /// What Genio is saying (output transcription).
  private var genioTranscript = ""
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
  /// Gemini turned the camera on: once a frame has been sent it is told to
  /// answer, instead of waiting for the user to repeat the question.
  private var cameraFollowUp: Date?
  /// Genio's current turn already said it turns the camera on (acted on once).
  private var cameraPhraseHeard = false
  /// Genio's turn is still open (audio came, turnComplete not yet), and
  /// when its last audio arrived: together with the playback queue they
  /// say whether Genio is speaking.
  private var modelTurnOpen = false
  private var lastModelAudio: Date?
  /// When the last camera frame went to Gemini.
  private var lastFrameSent: Date?
  /// Looks at the current step while the user is quiet.
  private var stepChecks = StepCheckPolicy()
  /// A silent check's reply is not played until then, unless a function
  /// result lets Genio speak (step confirmed, remark worth saying).
  private var checkMutedUntil: Date?
  /// When the user or Genio last spoke.
  private var lastSpeech: Date?
  /// When the user last spoke, and when Genio last produced audio or words
  /// (muted ones included): a warning waits for both to be quiet.
  private var lastUserSpeech: Date?
  private var lastModelOutput: Date?
  /// Warnings kept until Genio's words show they were said.
  private var delivery = RemarkDelivery()
  /// Slow calls (look_closely) still running, by call id: answered when
  /// done, unless Gemini cancelled them meanwhile.
  private var slowCalls: Set<String> = []

  init(audio: AudioManager, call: CallSession, glasses: GlassesManager, engine: TaskEngine) {
    self.audio = audio
    self.call = call
    self.glasses = glasses
    self.engine = engine
    tools = TaskTools(engine: engine)
    tools.recentUserSpeech = { [weak self] in self?.recentSpeech() ?? "" }
    tools.cameraIsOn = { [weak glasses] in glasses?.cameraActive ?? false }
    tools.onCameraRequest = { [weak self] on in self?.cameraControl?(on) ?? false }
    tools.onCloseLook = { [weak self] question in
      guard let closeLook = self?.closeLook else { return .failed("not available") }
      return await closeLook(question)
    }
  }

  var isActive: Bool { session != nil }
  /// Turns the glasses camera on or off for Gemini; false if it cannot.
  var cameraControl: ((Bool) -> Bool)?
  /// Takes a sharp still and asks a vision model about it (look_closely).
  var closeLook: ((String) async -> TaskTools.CloseLookResult)?
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
          systemInstruction: LiveInstructions.system(
            language: settings.languageName, snapshot: engine.snapshot(), memory: engine.memorySummary()),
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
    guard !inToolCall, session != nil, let text = LiveInstructions.stepEvent(event) else { return }
    syncedRevision = engine.task?.revision
    sendAppText(text)
  }

  /// A remark from the separate coach, to be said by Gemini. It goes out
  /// when nobody is talking and is kept until Genio is heard saying it
  /// (see RemarkDelivery).
  func relayRemark(_ remark: String, kind: RemarkKind) {
    guard session != nil else { return }
    delivery.queue(remark, kind: kind, step: currentStepRef(), now: Date())
  }

  private func handleDelivery(_ events: [RemarkDelivery.Event]) {
    for event in events {
      switch event {
      case .send(let remark, let retry):
        onLog?(retry ? "Warning not heard, saying it again: \(remark.text)" : "Warning: \(remark.text)")
        sendAppText(LiveInstructions.warning(remark.text, kind: remark.kind, retry: retry))
      case .delivered(let remark):
        onLog?("Warning heard: \(remark.text)")
      case .dropped(let remark, let reason):
        onLog?("Warning dropped (\(reason.rawValue)): \(remark.text)")
      }
    }
  }

  private func currentStepRef() -> RemarkDelivery.StepRef? {
    guard let task = engine.task, task.currentStep != nil else { return nil }
    return RemarkDelivery.StepRef(index: task.current, revision: task.revision)
  }

  /// A message from the app that Gemini answers aloud.
  private func sendAppText(_ text: String) {
    guard let session else { return }
    checkMutedUntil = nil
    Task { await session.sendText(text) }
  }

  private var checkMuted: Bool {
    guard let until = checkMutedUntil else { return false }
    return Date() < until
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
      lastModelOutput = Date()
      guard !checkMuted else { break }  // a silent check's reply
      audio.playVoice(pcm24k: pcm)
      isModelSpeaking = true
      modelTurnOpen = true
      lastModelAudio = Date()
      lastSpeech = Date()
    case .interrupted:
      // The user started talking: stop Genio's voice at once.
      audio.flushVoice()
      modelTurnOpen = false
      isModelSpeaking = false
      // A warning being said was cut off: it goes out again.
      handleDelivery(delivery.genioInterrupted(now: Date()))
    case .turnComplete, .generationComplete:
      // The voice may still be playing: refreshSpeaking() clears
      // isModelSpeaking once the queue has drained.
      modelTurnOpen = false
      isModelSpeaking = audio.isPlayingVoice
      if event == .turnComplete, !genioTurnEnded {
        genioTurnEnded = true
        let line = genioTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.isEmpty { onLog?("Genio: \(line)") }
        handleDelivery(delivery.genioFinishedTurn(line, now: Date()))
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
      lastSpeech = Date()
      lastUserSpeech = Date()
      checkMutedUntil = nil
      // A pending camera follow-up stays: the transcript of the request
      // itself often arrives after the call, and the follow-up quotes the
      // latest words anyway.
      // "Genio stop" switches off directly, whatever the model does.
      if !stopHeard, VoiceStop.matches(userTranscript) {
        stopHeard = true
        onLog?("Heard \"\(userTranscript.trimmingCharacters(in: .whitespaces))\": switching off")
        onPauseRequested?()
      }
    case .outputTranscript(let text):
      lastModelOutput = Date()
      guard !checkMuted else { break }
      if !userTurnEnded {
        userTurnEnded = true
        let line = userTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.isEmpty { onLog?("Heard: \(line)") }
      }
      if genioTurnEnded {
        genioTranscript = ""
        genioTurnEnded = false
        cameraPhraseHeard = false
      }
      genioTranscript += text
      // Genio said "accendo la fotocamera" without calling turn_on_camera:
      // the app turns it on, so the words are never left unkept.
      if !cameraPhraseHeard, CameraPhrase.announcesCameraOn(genioTranscript) {
        cameraPhraseHeard = true
        if cameraFollowUp == nil, !glasses.cameraActive, cameraControl?(true) == true {
          onLog?("Genio said it turns the camera on: turning it on")
          cameraFollowUp = Date()
        }
      }
    case .toolCall(let calls):
      var responses: [FunctionResponse] = []
      inToolCall = true
      for call in calls {
        if TaskTools.isSlow(call) {
          runSlow(call)
          continue
        }
        let response = tools.handle(call)
        if call.name == TaskTools.Name.turnOnCamera.rawValue, response.response["camera"]?.stringValue == "starting" {
          cameraFollowUp = cameraFollowUp ?? Date()
        }
        if response.response["advanced"] == .bool(true) || response.response["speak"] == .bool(true) {
          checkMutedUntil = nil  // something worth saying
        }
        if call.name == TaskTools.Name.reportObservation.rawValue, response.response["speak"] == .bool(true),
           let message = call.args["message"]?.stringValue {
          // Gemini says it itself: watched like a relayed one.
          let kind = call.args["kind"]?.stringValue.flatMap(RemarkKind.init(rawValue:)) ?? .mistake
          delivery.expect(message, kind: kind, step: currentStepRef(), now: Date())
        }
        onLog?("Tool \(call.name) → \(response.response["status"]?.stringValue ?? "?")")
        responses.append(response)
      }
      inToolCall = false
      syncedRevision = engine.task?.revision
      if !responses.isEmpty { await session?.respond(responses) }
    case .toolCallCancellation(let ids):
      for id in ids { slowCalls.remove(id) }
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
        sendAppText(LiveInstructions.greeting(language: languageName))
      }
    case .reconnecting(let attempt):
      status = .reconnecting(attempt)
      audio.flushVoice()
      modelTurnOpen = false
    case .stopped:
      status = .off
    case .failed(let reason):
      status = .failed(reason)
      onLog?("Gemini Live: \(reason)")
      cleanUp()
    }
  }

  /// A call that takes seconds (look_closely: a photo, then a vision
  /// request) runs on its own, so the conversation's audio and events keep
  /// flowing meanwhile; Gemini waits for its result.
  private func runSlow(_ call: FunctionCall) {
    slowCalls.insert(call.id)
    onLog?("Tool \(call.name): working…")
    Task { [weak self] in
      guard let self else { return }
      let response = await self.tools.handleSlow(call)
      // Cancelled by Gemini, or the session ended, meanwhile.
      guard self.slowCalls.remove(call.id) != nil, let session = self.session else { return }
      self.onLog?("Tool \(call.name) → \(response.response["status"]?.stringValue ?? "?")")
      self.checkMutedUntil = nil  // the answer is meant to be heard
      await session.respond([response])
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
    refreshSpeaking()
    defer { proactiveTick() }
    guard pacer.decide(frameTime: glasses.latestFrameTime, now: Date()) == .send else {
      syncMetrics(session)
      return
    }
    guard case let (jpeg, frameTime)? = await glasses.latestJPEGInBackground(maxAge: pacer.maxFrameAge, maxDimension: 768) else {
      pacer.finished(frameTime: Date(), now: Date(), sent: false)
      return
    }
    let sent = await session.sendVideo(jpeg)
    if sent { lastFrameSent = Date() }
    pacer.finished(frameTime: frameTime, now: Date(), sent: sent)
    syncMetrics(session)
  }

  /// What the app says to Gemini without the user speaking: "you can see
  /// now" after a camera request, a warning to say, and the periodic silent
  /// step check.
  private func proactiveTick() {
    guard let session, status == .live, !inToolCall, slowCalls.isEmpty else { return }
    let now = Date()
    let speaking = isModelSpeaking
    if let requestedAt = cameraFollowUp {
      if let frame = lastFrameSent, frame > requestedAt {
        // Let "turning the camera on" start and finish first.
        guard !speaking, now.timeIntervalSince(requestedAt) > 2 else { return }
        cameraFollowUp = nil
        onLog?("Camera ready: Gemini answers")
        lastSpeech = now
        // The words from just before the request to now: the question, and
        // anything the user added while the camera started.
        sendAppText(LiveInstructions.cameraReady(userRequest: speech(since: requestedAt.addingTimeInterval(-20))))
      } else if now.timeIntervalSince(requestedAt) > Self.cameraStartTimeout {
        cameraFollowUp = nil
        onLog?("Camera did not start")
        sendAppText(LiveInstructions.cameraFailed)
      }
      return
    }
    // Warnings first: sent once Genio has been quiet for a moment.
    let modelQuiet = lastModelOutput.map { now.timeIntervalSince($0) > 1 } ?? true
    handleDelivery(delivery.tick(now: now, step: currentStepRef(), canSpeak: !speaking && modelQuiet,
                                 lastUserSpeech: lastUserSpeech))
    // No silent check while a warning waits or is being said: the check
    // mutes Genio's reply, and the warning with it.
    guard delivery.isIdle, !speaking, !checkMuted else { return }
    let task = engine.task
    let step = task.flatMap { $0.currentStep != nil && !engine.paused ? ($0.current, $0.revision) : nil }
    guard stepChecks.shouldCheck(now: now, step: step, cameraOn: glasses.cameraActive, lastSpeech: lastSpeech),
          let task, let text = task.currentStep
    else { return }
    checkMutedUntil = now.addingTimeInterval(15)
    Task { await session.sendText(LiveInstructions.stepCheck(step: task.current + 1, text: text)) }
  }

  /// Long enough for GlassesManager to restart a camera that hangs on start.
  private static let cameraStartTimeout: TimeInterval = 20

  /// Genio is speaking while its turn is open or its voice still plays.
  /// turnComplete usually arrives before the voice has finished playing, so
  /// this is checked again on every tick; a turn whose audio stopped coming
  /// without a turnComplete (lost on a reconnect) counts as over after 3 s.
  private func refreshSpeaking() {
    let turnOpen = modelTurnOpen && lastModelAudio.map { Date().timeIntervalSince($0) < 3 } == true
    let speaking = turnOpen || audio.isPlayingVoice
    if isModelSpeaking != speaking { isModelSpeaking = speaking }
  }

  private func syncMetrics(_ session: GeminiLiveSession) {
    metrics.framesSent = pacer.metrics.sent
    metrics.framesDropped = pacer.metrics.droppedStale + pacer.metrics.droppedBusy + pacer.metrics.failed
    metrics.frameLatency = pacer.metrics.averageLatency
  }

  // MARK: - Helpers

  private func recentSpeech() -> String {
    speech(since: Date().addingTimeInterval(-20))
  }

  /// What the user said since `start` (kept for a minute).
  private func speech(since start: Date) -> String {
    let cutoff = Date().addingTimeInterval(-60)
    heard.removeAll { $0.0 < cutoff }
    return heard.filter { $0.0 >= start }.map(\.1).joined(separator: " ")
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
    cameraFollowUp = nil
    cameraPhraseHeard = false
    modelTurnOpen = false
    lastModelAudio = nil
    lastFrameSent = nil
    stepChecks = StepCheckPolicy()
    checkMutedUntil = nil
    lastSpeech = nil
    lastUserSpeech = nil
    lastModelOutput = nil
    delivery.reset()
    slowCalls.removeAll()
  }
}
