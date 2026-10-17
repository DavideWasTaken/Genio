import Foundation
import MWDATInputs
import UIKit

/// A hands-on task split into steps, and where the user is in it.
struct GenioTask: Equatable {
  let id = UUID()
  let goal: String
  var steps: [String]
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
  /// Use the other brain when the main one cannot answer (default on).
  static let useBackup = "useBackup"
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
  /// What Genio said last, as normalized words, and when it stopped: the
  /// glasses' mic can pick up Genio's own voice, and those echoes must not
  /// be taken for the user.
  private var lastSpokenWords: Set<String> = []
  private var lastSpokenEnd = Date.distantPast
  /// Whether the sentence being recognised began while Genio was talking
  /// (or right after): the glasses' mic hears Genio, and the recogniser
  /// garbles it ("Ok, preparo" -> "OK Meta"), so timing tells echoes apart
  /// better than words do.
  private var utteranceInProgress = false
  private var utteranceOverlapsGenio = false
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
    NotificationCenter.default.addObserver(forName: GenioLog.notification, object: nil, queue: .main) { [weak self] note in
      guard let line = note.userInfo?["line"] as? String else { return }
      MainActor.assumeIsolated { self?.note(line) }
    }
  }

  private var defaults: UserDefaults { .standard }

  /// The main brain (Claude with the API key, or ChatGPT on your plan) and,
  /// unless turned off, the other one as backup.
  private var brain: any Brain {
    let claude = ClaudeBrain(
      apiKey: Keychain.apiKey ?? "",
      smartModel: defaults.string(forKey: SettingKey.smartModel) ?? "claude-opus-5-5")
    let chatgpt = ChatGPTBrain(
      coachModel: defaults.string(forKey: SettingKey.chatgptCoachModel) ?? "",
      smartModel: defaults.string(forKey: SettingKey.chatgptSmartModel) ?? "")
    let chatgptIsMain = defaults.string(forKey: SettingKey.provider) == "chatgpt"
    let useBackup = defaults.object(forKey: SettingKey.useBackup) as? Bool ?? true
    if chatgptIsMain {
      if useBackup { return FallbackBrain(primary: chatgpt, backup: claude) }
      return chatgpt
    }
    if useBackup { return FallbackBrain(primary: claude, backup: chatgpt) }
    return claude
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
    // No glasses, no GENIO: it needs their camera, button and microphone.
    guard glasses.status == .streaming else {
      note("GENIO needs the glasses connected first")
      return
    }
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
    if !utteranceInProgress {
      utteranceInProgress = true
      utteranceOverlapsGenio = voice.isSpeaking || Date().timeIntervalSince(lastSpokenEnd) < 0.8
    }
    guard isFinal else { return }
    let overlapped = utteranceOverlapsGenio
    utteranceInProgress = false
    let words = Self.normalize(text)
    guard !words.isEmpty else { return }

    if overlapped {
      // Begun over Genio's voice: almost always its echo. Only a command
      // gets through (to interrupt it), and only the command part.
      guard let command = commandPart(of: words) else {
        note("Heard while Genio spoke, ignored: \(text)")
        return
      }
      note("Heard over Genio's voice, kept the command: \(command)")
      if voice.isSpeaking { voice.stop() }
      act(on: command, words: command)
      return
    }
    if isEcho(words) {
      note("Heard (Genio's own voice, ignored): \(text)")
      return
    }
    note("Heard: \(text)")
    // The user talks over Genio: stop reading and listen.
    if voice.isSpeaking { voice.stop() }
    act(on: text, words: words)
  }

  /// The command inside a sentence that mixes Genio's echo with the user's
  /// words: the wake word and what follows it, or a step command at the end
  /// ("... della finestra fatto" -> "fatto").
  private func commandPart(of words: String) -> String? {
    let tokens = words.split(separator: " ").map(String.init)
    // Genio says its own name ("Genio attivo…"): in an echo of that line the
    // name is not the user calling it.
    if let index = tokens.firstIndex(where: language.wakeWords.contains),
       !lastSpokenWords.contains(tokens[index]) {
      return tokens[index...].joined(separator: " ")
    }
    let commands = language.nextWords.union(language.repeatWords)
      .union(language.backWords).union(language.newTaskWords)
    for length in stride(from: min(4, tokens.count), through: 1, by: -1) {
      let tail = tokens.suffix(length).joined(separator: " ")
      if commands.contains(tail) { return tail }
    }
    return nil
  }

  /// Acts on a sentence that is for Genio.
  private func act(on text: String, words: String) {
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
      if active, task?.currentStep != nil {
        followUp(original)
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
      // While guiding, whatever the user says is for Genio: "I can't find
      // it", "there's no such button", "I'm on a Mac". The model answers
      // with what it sees and may rewrite the remaining steps.
      if task?.currentStep != nil {
        followUp(text)
        return
      }
    }
    if Date() < questionWindowUntil {
      questionWindowUntil = .distantPast
      ask(text)
    }
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

  /// A reply while guiding: spoken, and, when the plan did not fit, the
  /// remaining steps replaced by the corrected ones.
  private func followUp(_ message: String) {
    guard !thinking, let snapshot = task, !snapshot.finished else { return }
    thinking = true
    let image = glasses.latestJPEG()
    let brain = self.brain
    Task {
      defer { thinking = false }
      do {
        let reply = try await brain.followUp(
          message: message, image: image, goal: snapshot.goal,
          steps: snapshot.steps, current: snapshot.current)
        let corrected = reply.remainingSteps.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !corrected.isEmpty, var now = task, now.id == snapshot.id, now.current == snapshot.current {
          now.steps = Array(now.steps.prefix(now.current)) + corrected.prefix(max(1, 12 - now.current))
          now.recentRemarks = []
          task = now
          note("Plan updated: \(corrected.count) steps from step \(now.current + 1)")
          startCoach()
        }
        let line = reply.say.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty {
          note("Not for Genio, ignored")
        } else {
          say(line)
        }
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
    lastSpokenWords = Set(Self.normalize(text).split(separator: " ").map { Self.canonical(String($0)) })
    let languageCode = language.voiceCode
    Task {
      await voice.speak(text, languageCode: languageCode)
      lastSpokenEnd = Date()
    }
  }

  /// True when what was heard is Genio's own last line coming back through
  /// the glasses' mic: heard while (or just after) it spoke, and made of its
  /// words. A short command like "done" is never treated as an echo.
  private func isEcho(_ words: String) -> Bool {
    guard voice.isSpeaking || Date().timeIntervalSince(lastSpokenEnd) < 3 else { return false }
    let heard = words.split(separator: " ").map { Self.canonical(String($0)) }
    guard heard.count >= 3 else { return false }
    let shared = heard.filter(lastSpokenWords.contains).count
    return Double(shared) / Double(heard.count) >= 0.6
  }

  /// One spelling per number, so "4 passi. Primo" said by Genio matches
  /// "quattro passi uno" heard back through the mic.
  private static let numberWords: [String: String] = [
    "un": "1", "uno": "1", "una": "1", "primo": "1", "prima": "1", "one": "1", "first": "1",
    "due": "2", "two": "2", "tre": "3", "three": "3", "quattro": "4", "four": "4",
    "cinque": "5", "five": "5", "sei": "6", "six": "6", "sette": "7", "seven": "7",
    "otto": "8", "eight": "8", "nove": "9", "nine": "9", "dieci": "10", "ten": "10",
    "undici": "11", "eleven": "11", "dodici": "12", "twelve": "12",
  ]

  private static func canonical(_ word: String) -> String {
    numberWords[word] ?? word
  }

  private func note(_ line: String) {
    NSLog("[Genio] %@", line)
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
