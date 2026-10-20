import Combine
import Foundation
import GenioCore
import MWDATInputs
import UIKit

/// Setting keys, shared with the settings screen.
enum SettingKey {
  static let pressType = "pressType"
  static let geminiVoice = "geminiVoice"
  /// The coach's model, picked automatically and cached.
  static let coachModelResolved = "coachModelResolved"
}

/// Fixed choices that used to be settings: the defaults are right for
/// almost everyone, and fewer knobs means fewer ways to break it.
enum Tuning {
  /// Frames per second sent to Gemini Live (the API's maximum).
  static let framesPerSecond = 1.0
  /// Seconds between two looks of the vision coach.
  static let coachInterval: TimeInterval = 6
}

/// GENIO's behaviour:
///
///  - Press the glasses' capture button (or the big button on screen): GENIO
///    on. A Gemini Live session opens: Gemini hears you through the glasses'
///    microphone, sees through their camera (about one frame a second) and
///    answers in its own voice on the glasses' speakers.
///  - Say what you are doing: Gemini proposes a plan, TaskEngine validates it
///    and guides you one step at a time. The step moves on when you say so,
///    or when the camera shows it done consistently (Gemini's own looks and
///    the separate vision coach, checked by TaskEngine).
///  - Ask anything, any time; "new task", "back", "stop" work as you'd say
///    them.
///  - Press again (or say "Genio stop"): GENIO off. The task is saved, even
///    across app restarts; the next press resumes it.
@MainActor
final class GenioController: ObservableObject {
  @Published private(set) var active = false
  @Published private(set) var log: [String] = []

  let glasses = GlassesManager()
  let audio = AudioManager()
  /// GENIO sessions as calls, so the microphone can start from the background.
  let call = CallSession()
  let taskEngine = TaskEngine(store: FileTaskStore.standard())
  private(set) lazy var live = LiveConversationEngine(audio: audio, call: call, glasses: glasses, engine: taskEngine)
  private lazy var voice = Voice(audio: audio)
  private lazy var coach = CoachEngine(
    engine: taskEngine, glasses: glasses,
    makeCoach: { [unowned self] in await self.visionCoach() },
    interval: { Tuning.coachInterval },
    isBusy: { [unowned self] in self.live.isModelSpeaking })
  private var cancellables: Set<AnyCancellable> = []

  /// The task, as TaskEngine knows it.
  var task: GenioTask? { taskEngine.task }

  /// Read on every use, so a change in Settings applies at once.
  private var language: VoiceLanguage { VoiceLanguage.current }
  private var defaults: UserDefaults { .standard }

  init() {
    glasses.onPress = { [weak self] press in self?.handlePress(press) }
    glasses.onLog = { [weak self] line in self?.note("Glasses: \(line)") }
    glasses.observeRegistration()
    audio.onLog = { [weak self] line in self?.note(line) }
    live.onLog = { [weak self] line in self?.note(line) }
    live.onPauseRequested = { [weak self] in self?.pauseRequestedByLive() }
    // The camera starts off; Gemini turns it on when it needs to see.
    live.cameraControl = { [weak self] on in
      guard let self, self.active, self.glasses.status == .connected else { return false }
      self.note("Camera \(on ? "on" : "off") (asked by Gemini)")
      self.glasses.setCamera(needed: on, by: "genio")
      return true
    }
    live.closeLook = { [weak self] question in
      await self?.closeLook(question) ?? .failed("not available")
    }
    call.onLog = { [weak self] line in self?.note(line) }
    // The user hung up from the Dynamic Island or the lock screen.
    call.onEndedBySystem = { [weak self] in self?.stop() }
    coach.onLog = { [weak self] line in self?.note(line) }
    coach.onRemark = { [weak self] remark, kind in self?.live.relayRemark(remark, kind: kind) }
    taskEngine.onEvent = { [weak self] event in self?.taskChanged(event) }
    // The screens follow the engine and the live conversation.
    taskEngine.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
    live.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
    // The session gave up (bad key, no network for too long): switch off.
    live.$status.sink { [weak self] status in
      guard case .failed(let reason) = status else { return }
      Task { @MainActor in self?.liveFailed(reason) }
    }.store(in: &cancellables)
    // Glasses connected and GENIO off: keep the app alive for the button.
    glasses.$status.removeDuplicates().sink { [weak self] _ in
      Task { @MainActor in self?.restoreIdleAudio() }
    }.store(in: &cancellables)
    NotificationCenter.default.addObserver(forName: GenioLog.notification, object: nil, queue: .main) { [weak self] note in
      guard let line = note.userInfo?["line"] as? String else { return }
      MainActor.assumeIsolated { self?.note(line) }
    }
    if let task = taskEngine.task {
      note("Restored: \(task.goal), step \(task.current + 1) of \(task.steps.count)")
    }
  }

  // MARK: - Button

  private func handlePress(_ press: CapturePressType) {
    let wanted = defaults.string(forKey: SettingKey.pressType) ?? "shortPress"
    let name: String
    switch press {
    case .shortPress: name = "shortPress"
    case .doublePress: name = "doublePress"
    case .hold: name = "hold"
    }
    note("Button: \(name)")
    guard name == wanted else { return }
    toggle()
  }

  /// Same as the glasses' button; also used by the big button on screen.
  func toggle() {
    if active { stop() } else { start() }
  }

  func start() {
    guard !active else { return }
    // No glasses, no GENIO: it needs their camera, button and microphone.
    guard glasses.status == .connected else {
      note("GENIO needs the glasses connected first")
      return
    }
    guard let key = Keychain.geminiKey, !key.isEmpty else {
      note("GENIO needs a Gemini API key (Settings)")
      speakFallback(.noGeminiKey)
      return
    }
    active = true
    UIApplication.shared.isIdleTimerDisabled = true
    taskEngine.resume()
    if task?.finished == true { taskEngine.clear() }
    let settings = LiveConversationEngine.Settings(
      apiKey: key,
      model: LiveConversationEngine.defaultModel,
      voice: defaults.string(forKey: SettingKey.geminiVoice) ?? LiveConversationEngine.defaultVoice,
      framesPerSecond: Tuning.framesPerSecond,
      languageName: language.promptName)
    note("GENIO on (\(settings.model))")
    Task {
      await live.start(settings)
      guard active, live.isActive else { return }
      voice.chime(.on)
      updateCoach()
    }
  }

  func stop() {
    guard active else { return }
    active = false
    coach.stop()
    taskEngine.pause()
    live.stop()
    // Idle glasses keep only the button: the camera stops to save battery.
    glasses.setCamera(needed: false, by: "genio")
    voice.chime(.off)
    UIApplication.shared.isIdleTimerDisabled = false
    note("GENIO off")
    // Give the chime time to play, then release the microphone. The call
    // ends asynchronously: if standby cannot start yet, try once more.
    Task {
      try? await Task.sleep(for: .seconds(0.6))
      restoreIdleAudio()
      try? await Task.sleep(for: .seconds(1.5))
      restoreIdleAudio()
    }
  }

  /// The audio GENIO-off needs: standby (silent, keeps iOS from suspending
  /// the app so the glasses' button still works in the background) while the
  /// glasses are connected, nothing otherwise.
  func restoreIdleAudio() {
    guard !active else { return }
    if glasses.status == .connected {
      audio.configureStandby()
    } else if audio.mode != .idle {
      audio.deactivate()
    }
  }

  /// Gemini heard "Genio stop": let its goodbye play, then switch off.
  private func pauseRequestedByLive() {
    Task {
      try? await Task.sleep(for: .seconds(2.5))
      guard active else { return }
      stop()
    }
  }

  private func liveFailed(_ reason: String) {
    guard active else { return }
    note("Gemini Live stopped: \(reason)")
    stop()
    if reason.localizedCaseInsensitiveContains("key") {
      speakFallback(.noGeminiKey)
    } else if live.lastFailureWasAudio {
      speakFallback(.microphoneUnavailable)
    } else {
      speakFallback(.unreachable)
    }
  }

  // MARK: - Task events

  /// TaskEngine changed the task: Gemini says what needs saying, the coach
  /// runs only while there is a step to check.
  private func taskChanged(_ event: TaskEvent) {
    guard active else { return }
    live.taskEventOccurred(event)
    switch event {
    case .finished, .cleared:
      // Nothing left to check: the camera goes off until Gemini needs it.
      glasses.setCamera(needed: false, by: "genio")
    default:
      break
    }
    updateCoach()
  }

  private func updateCoach() {
    let hasStep = task?.currentStep != nil && !taskEngine.paused
    if active, hasStep, live.isActive {
      coach.start()
    } else {
      coach.stop()
    }
  }

  /// The vision coach for this look: the key, and the newest stable "flash"
  /// model the key can use (looked up once, then cached).
  private func visionCoach() async -> GeminiVisionCoach? {
    guard let key = Keychain.geminiKey, !key.isEmpty else { return nil }
    var model = defaults.string(forKey: SettingKey.coachModelResolved) ?? ""
    if model.isEmpty {
      let models = (try? await GeminiVisionCoach.listModels(apiKey: key)) ?? []
      model = GeminiVisionCoach.pickDefault(from: models) ?? GeminiVisionCoach.fallbackModel
      defaults.set(model, forKey: SettingKey.coachModelResolved)
      note("Coach model: \(model)")
    }
    return GeminiVisionCoach(apiKey: key, model: model, languageName: language.promptName)
  }

  /// look_closely: a sharp still from the glasses, looked at by the coach's
  /// vision model at high resolution.
  private func closeLook(_ question: String) async -> TaskTools.CloseLookResult {
    guard let image = await glasses.closeLookImage() else {
      note("Close look: no image")
      return .noImage
    }
    guard let coach = await visionCoach() else { return .failed("no Gemini API key") }
    let looker = GeminiCloseLook(apiKey: coach.apiKey, model: coach.model, languageName: coach.languageName)
    note("Close look (\(image.source), \(image.data.count / 1024) KB): \(question)")
    do {
      let found = try await looker.look(image: image.data, question: question, goal: task?.goal, step: task?.currentStep)
      note("Close look: \(found.confident ? "" : "not sure, ")\(found.answer)")
      return .answer(found, source: image.source)
    } catch {
      note("Close look: \(error.localizedDescription)")
      return .failed(error.localizedDescription)
    }
  }

  // MARK: - Helpers

  /// A short line in the iOS voice, for when Gemini cannot speak.
  private func speakFallback(_ line: VoiceLanguage.Line) {
    // Inside the standby session when the glasses are connected: it is
    // mixable, so it also works from the background (a fresh, non-mixable
    // session would be refused there).
    restoreIdleAudio()
    if audio.mode != .standby { voice.configure(route: .media) }
    let text = language.say(line)
    note("Genio: \(text)")
    let code = language.voiceCode
    Task {
      await voice.speak(text, languageCode: code)
      restoreIdleAudio()
    }
  }

  private func note(_ line: String) {
    NSLog("[Genio] %@", line)
    log.append(line)
    if log.count > 80 { log.removeFirst(log.count - 80) }
  }
}
