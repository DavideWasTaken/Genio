import Foundation
import MWDATInputs
import UIKit

/// A hands-on task split into steps, and where the user is in it.
struct GenioTask: Equatable {
  let id = UUID()
  let goal: String
  let steps: [String]
  var current = 0
  var recentRemarks: [String] = []

  var finished: Bool { current >= steps.count }
  var currentStep: String? { finished ? nil : steps[current] }

  var summary: String {
    finished ? "Ha finito: \(goal)." : "\(goal), passo \(current + 1) di \(steps.count): \(steps[current])"
  }
}

/// Setting keys, shared with the settings screen.
enum SettingKey {
  static let pressType = "pressType"
  static let coachInterval = "coachInterval"
  static let audioRoute = "audioRoute"
  static let smartModel = "smartModel"
  /// "claude" or "chatgpt".
  static let provider = "provider"
  static let chatgptSmartModel = "chatgptSmartModel"
  static let chatgptCoachModel = "chatgptCoachModel"
}

/// GENIO's behaviour (commands shown in English; see VoiceLanguage for the
/// Italian ones):
///
///  - Press the glasses' capture button: GENIO mode on. It asks what you are
///    doing, plans the steps with the model, reads you one step at a time and
///    a coach (a fast model looking at the camera every few seconds) moves you
///    on when it sees a step done, or warns you about a mistake.
///    "Done" / "next", "repeat", "back", "new task" steer it.
///  - Press again (or say "Genio stop"): GENIO mode off. The task is kept;
///    the next press resumes it.
///  - Any time, "Genio, <question>": a quick spoken answer, with what the
///    camera sees. "Genio" alone: it says "Yes?" and takes the next sentence
///    as the question.
@MainActor
final class GenioController: ObservableObject {
  @Published private(set) var active = false
  @Published private(set) var task: GenioTask?
  @Published private(set) var thinking = false
  @Published private(set) var heard = ""
  @Published private(set) var log: [String] = []

  let glasses = Glasses()
  private let voice = Voice()

  private var coachLoop: Task<Void, Never>?
  private var awaitingGoal = false
  private var questionWindowUntil = Date.distantPast
  private var ignoreSpeechUntil = Date.distantPast
  private var lastRemarkAt = Date.distantPast

  /// Read on every use, so a change in Settings applies at once.
  private var language: VoiceLanguage { VoiceLanguage.current }

  /// Least time between two remarks the coach makes unasked.
  private let minRemarkGap: TimeInterval = 15

  init() {
    glasses.onPress = { [weak self] press in self?.handlePress(press) }
    glasses.onTranscript = { [weak self] text, isFinal in self?.handleTranscript(text, isFinal: isFinal) }
    glasses.onLog = { [weak self] line in self?.note("Glasses: \(line)") }
    glasses.observeRegistration()
  }

  private var defaults: UserDefaults { .standard }

  /// Claude with the API key, or ChatGPT on your plan. With ChatGPT and a
  /// Claude key both set, Claude covers for ChatGPT when the plan's usage
  /// limit is reached or the sign-in has expired.
  private var brain: any Brain {
    let claude = ClaudeBrain(
      apiKey: Keychain.apiKey ?? "",
      smartModel: defaults.string(forKey: SettingKey.smartModel) ?? "claude-opus-5-5")
    guard defaults.string(forKey: SettingKey.provider) == "chatgpt" else { return claude }
    let chatgpt = ChatGPTBrain(
      coachModel: defaults.string(forKey: SettingKey.chatgptCoachModel) ?? "",
      smartModel: defaults.string(forKey: SettingKey.chatgptSmartModel) ?? "")
    if (Keychain.apiKey ?? "").isEmpty { return chatgpt }
    return FallbackBrain(primary: chatgpt, backup: claude)
  }

  private var coachInterval: TimeInterval {
    let value = defaults.double(forKey: SettingKey.coachInterval)
    return value > 0 ? value : 6
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
    active = true
    UIApplication.shared.isIdleTimerDisabled = true
    voice.configure(route: Voice.Route(rawValue: defaults.string(forKey: SettingKey.audioRoute) ?? "") ?? .media)
    voice.chime(.on)
    if let task, let step = task.currentStep {
      say(.resume(goal: task.goal, step: task.current + 1, text: step))
      startCoach()
    } else {
      task = nil
      awaitingGoal = true
      say(.awake)
    }
  }

  /// `interrupt`: cut Genio off mid-sentence (the button). The spoken
  /// "Genio stop" passes false so its goodbye is still heard.
  func stop(interrupt: Bool = true) {
    guard active else { return }
    active = false
    awaitingGoal = false
    coachLoop?.cancel()
    coachLoop = nil
    if interrupt { voice.stop() }
    voice.chime(.off)
    UIApplication.shared.isIdleTimerDisabled = false
    note("GENIO off")
  }

  // MARK: - Voice

  private func handleTranscript(_ text: String, isFinal: Bool) {
    heard = text
    guard isFinal else { return }
    // The glasses' mic can hear Genio's own voice: ignore what arrives while
    // it speaks and just after.
    guard !voice.isSpeaking, Date() > ignoreSpeechUntil else { return }
    let words = Self.normalize(text)
    guard !words.isEmpty else { return }
    note("Heard: \(text)")

    // "Genio ..." anywhere in the sentence (as a word, not inside one):
    // what follows is for us.
    let tokens = words.split(separator: " ").map(String.init)
    if let index = tokens.firstIndex(where: language.wakeWords.contains) {
      let after = tokens[(index + 1)...].joined(separator: " ")
      let original = textAfterWakeWord(in: text)
      if active, language.stopWords.contains(after) {
        stop(interrupt: false)
        say(.goodbye)
        return
      }
      if after.isEmpty {
        questionWindowUntil = Date().addingTimeInterval(8)
        say(.tellMe)
        return
      }
      if active, handleCommand(after) { return }
      if active, awaitingGoal {
        planTask(original)
        return
      }
      ask(original)
      return
    }

    if active {
      if handleCommand(words) { return }
      if awaitingGoal {
        planTask(text)
        return
      }
    }
    if Date() < questionWindowUntil {
      questionWindowUntil = .distantPast
      ask(text)
    }
    // Anything else said during GENIO mode (talking to someone, thinking
    // aloud) is ignored on purpose: questions start with "Genio".
  }

  /// Step commands during GENIO mode. Exact phrases only, so that
  /// "I made a mistake, done that wrong" is not taken as "done".
  private func handleCommand(_ words: String) -> Bool {
    if language.newTaskWords.contains(words) {
      coachLoop?.cancel()
      task = nil
      awaitingGoal = true
      say(.whatNow)
      return true
    }
    guard var current = task, !awaitingGoal else { return false }
    if language.nextWords.contains(words) {
      advance()
      return true
    }
    if language.repeatWords.contains(words), let step = current.currentStep {
      say(.step(current.current + 1, step))
      return true
    }
    if language.backWords.contains(words) {
      current.current = max(0, current.current - 1)
      task = current
      if let step = current.currentStep { say(.step(current.current + 1, step)) }
      startCoach()
      return true
    }
    return false
  }

  // MARK: - Claude

  private func planTask(_ request: String) {
    guard !thinking else { return }
    awaitingGoal = false
    thinking = true
    say(.planning)
    let image = glasses.latestJPEG()
    let brain = self.brain
    Task {
      defer { thinking = false }
      do {
        let plan = try await brain.plan(request: request, image: image)
        guard active else { return }
        let steps = plan.steps.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first = steps.first else {
          awaitingGoal = true
          say(.notUnderstood)
          return
        }
        let newTask = GenioTask(goal: plan.goal, steps: Array(steps.prefix(12)))
        task = newTask
        say(.planReady(goal: newTask.goal, count: newTask.steps.count, first: first))
        startCoach()
      } catch {
        awaitingGoal = true
        say(Self.spokenLine(for: error))
      }
    }
  }

  private func ask(_ question: String) {
    guard !thinking else { return }
    thinking = true
    let image = glasses.latestJPEG()
    let context = (active ? task?.summary : nil)
    let brain = self.brain
    Task {
      defer { thinking = false }
      do {
        let reply = try await brain.answer(question: question, image: image, taskContext: context)
        say(reply)
      } catch {
        say(Self.spokenLine(for: error))
      }
    }
  }

  private func advance() {
    guard var current = task, !current.finished else { return }
    current.current += 1
    current.recentRemarks = []
    task = current
    if let step = current.currentStep {
      say(.step(current.current + 1, step))
      startCoach()
    } else {
      coachLoop?.cancel()
      say(.allDone(goal: current.goal))
    }
  }

  // MARK: - Coach

  private func startCoach() {
    coachLoop?.cancel()
    coachLoop = Task { [weak self] in
      while !Task.isCancelled {
        guard let interval = self?.coachInterval else { return }
        try? await Task.sleep(for: .seconds(interval))
        guard let self, !Task.isCancelled, self.active else { return }
        await self.coachTick()
      }
    }
  }

  private func coachTick() async {
    guard !thinking, !voice.isSpeaking, let snapshot = task, let step = snapshot.currentStep,
          let image = glasses.latestJPEG()
    else { return }
    do {
      let verdict = try await brain.coach(
        image: image, goal: snapshot.goal, steps: snapshot.steps,
        current: snapshot.current, recentRemarks: snapshot.recentRemarks)
      // The world moved on while Claude was looking: a command, a question,
      // or GENIO switched off. Its verdict is about a step that is gone.
      guard active, !thinking, !voice.isSpeaking, let now = task,
            now.id == snapshot.id, now.current == snapshot.current
      else { return }
      if verdict.stepDone {
        note("Coach: done \"\(step)\"")
        advance()
        return
      }
      let remark = verdict.say.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !remark.isEmpty, Date().timeIntervalSince(lastRemarkAt) >= minRemarkGap else { return }
      lastRemarkAt = Date()
      task?.recentRemarks.append(remark)
      say(remark)
    } catch {
      note("Coach: \(error.localizedDescription)")
    }
  }

  // MARK: - Helpers

  private func say(_ line: VoiceLanguage.Line) {
    say(language.say(line))
  }

  private func say(_ text: String) {
    note("Genio: \(text)")
    let languageCode = language.voiceCode
    Task {
      await voice.speak(text, languageCode: languageCode)
      ignoreSpeechUntil = Date().addingTimeInterval(0.8)
    }
  }

  private func note(_ line: String) {
    log.append(line)
    if log.count > 60 { log.removeFirst(log.count - 60) }
  }

  private static func spokenLine(for error: Error) -> VoiceLanguage.Line {
    switch error as? BrainError {
    case .noKey: return .noClaudeKey
    case .notSignedIn: return .notSignedIn
    case .usageLimit: return .usageLimit
    default: return .unreachable
    }
  }

  private static let wordCharacters = CharacterSet.letters.union(.decimalDigits)

  /// Lowercased, accents folded, punctuation turned into spaces, single-spaced.
  static func normalize(_ text: String) -> String {
    let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "it_IT"))
    let cleaned = folded.unicodeScalars.map { wordCharacters.contains($0) ? Character($0) : " " }
    return String(cleaned).split(separator: " ").joined(separator: " ")
  }

  /// The original words after the wake word, for a question that keeps
  /// its punctuation.
  func textAfterWakeWord(in text: String) -> String {
    let pattern = "\\b(" + language.wakeWords.joined(separator: "|") + ")\\b"
    guard let range = text.range(
      of: pattern, options: [.regularExpression, .caseInsensitive, .diacriticInsensitive])
    else { return text }
    return String(text[range.upperBound...])
      .trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
  }
}
