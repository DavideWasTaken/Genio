import Combine
import Foundation

/// Something the task engine did that the user should hear about or see.
public enum TaskEvent: Equatable, Sendable {
  case planCreated(GenioTask)
  /// The current step changed: `reason` says why.
  case stepChanged(GenioTask, reason: StepChangeReason)
  case finished(GenioTask)
  /// The steps from `fromStep` (0-based) on were replaced.
  case planRevised(GenioTask, fromStep: Int)
  /// The task was dropped ("new task").
  case cleared
}

public enum StepChangeReason: String, Codable, Sendable {
  /// The user said "done" / "next".
  case userConfirmed
  /// The camera showed it done, consistently (CompletionVerifier).
  case verified
  /// The user said "back".
  case back
}

/// What a remark is about, for deciding whether it is worth saying.
public enum RemarkKind: String, Codable, Sendable, CaseIterable {
  /// Heat, blades, electricity, spills, a falling part: worth interrupting.
  case hazard
  /// A clear mistake: wrong part, wrong order, wrong orientation.
  case mistake
  /// Worth remembering, not worth saying.
  case info
}

/// Why a plan or a change to it was refused.
public enum PlanError: Error, Equatable, Sendable, CustomStringConvertible {
  case emptyGoal
  case tooFewSteps(min: Int)
  case tooManySteps(max: Int)
  case stepTooLong(max: Int)
  case noTask
  case taskFinished
  case wrongStartStep(current: Int)

  public var description: String {
    switch self {
    case .emptyGoal: return "goal is empty"
    case .tooFewSteps(let min): return "a plan needs at least \(min) steps"
    case .tooManySteps(let max): return "a plan can have at most \(max) steps in total"
    case .stepTooLong(let max): return "each step must be one short sentence (max \(max) characters)"
    case .noTask: return "there is no task in progress"
    case .taskFinished: return "the task is already finished"
    case .wrongStartStep(let current):
      return "changes must start at the current step, number \(current + 1): completed steps cannot be changed and steps cannot be skipped"
    }
  }
}

/// The source of truth about the task: the plan, the current step, what was
/// seen, what the user changed. Models (Gemini Live, the coach) only
/// *propose*: a plan, a revision, a completion, an observation. The engine
/// validates every proposal and is the only one that changes the state.
///
/// Every change is saved through `store`, so closing the app or losing the
/// connection loses nothing.
@MainActor
public final class TaskEngine: ObservableObject {
  @Published public private(set) var task: GenioTask?
  /// GENIO switched off with a task in progress: kept, resumed next time.
  @Published public private(set) var paused = false
  /// Recent looks at the task, newest last (memory for the models and the UI).
  @Published public private(set) var observations: [StepObservation] = []

  /// Called for every change the user should hear about.
  public var onEvent: ((TaskEvent) -> Void)?

  public var verifier: CompletionVerifier
  /// Least time between two unasked remarks, by kind (hazards may come sooner).
  public var remarkGap: [RemarkKind: TimeInterval] = [.hazard: 5, .mistake: 15]

  private let store: TaskStore?
  private let now: () -> Date
  private var lastRemarkAt = Date.distantPast
  private let memorySize = 12

  public init(store: TaskStore? = nil, verifier: CompletionVerifier = CompletionVerifier(), now: @escaping () -> Date = Date.init) {
    self.store = store
    self.verifier = verifier
    self.now = now
    if let saved = store?.load(), let savedTask = saved.task, !savedTask.finished {
      task = savedTask
      paused = true
      observations = saved.observations
    }
  }

  // MARK: - Plans

  /// Starts a new task. `strict` (model proposals through tools) refuses
  /// plans outside 3–12 steps so the model can fix them; the classic path
  /// keeps its old leniency (any non-empty plan, cut at 12).
  @discardableResult
  public func startTask(goal: String, steps: [String], strict: Bool) -> Result<GenioTask, PlanError> {
    let title = goal.trimmingCharacters(in: .whitespacesAndNewlines)
    var cleaned = PlanRules.clean(steps)
    guard !title.isEmpty else { return .failure(.emptyGoal) }
    if strict {
      guard cleaned.count >= PlanRules.minSteps else { return .failure(.tooFewSteps(min: PlanRules.minSteps)) }
      guard cleaned.count <= PlanRules.maxSteps else { return .failure(.tooManySteps(max: PlanRules.maxSteps)) }
      guard cleaned.allSatisfy({ $0.count <= PlanRules.maxStepLength }) else {
        return .failure(.stepTooLong(max: PlanRules.maxStepLength))
      }
    } else {
      guard !cleaned.isEmpty else { return .failure(.tooFewSteps(min: 1)) }
      cleaned = Array(cleaned.prefix(PlanRules.maxSteps))
    }
    let newTask = GenioTask(goal: String(title.prefix(PlanRules.maxGoalLength)), steps: cleaned)
    task = newTask
    paused = false
    observations = []
    verifier.reset()
    save()
    onEvent?(.planCreated(newTask))
    return .success(newTask)
  }

  /// Replaces the steps from `fromStep` (0-based) to the end. Only the
  /// current step and later ones can change: completed steps are history,
  /// and starting later would silently skip the current one.
  @discardableResult
  public func reviseRemaining(fromStep: Int, steps: [String], reason: String?, strict: Bool) -> Result<GenioTask, PlanError> {
    guard var current = task else { return .failure(.noTask) }
    guard !current.finished else { return .failure(.taskFinished) }
    guard fromStep == current.current else { return .failure(.wrongStartStep(current: current.current)) }
    var cleaned = PlanRules.clean(steps)
    guard !cleaned.isEmpty else { return .failure(.tooFewSteps(min: 1)) }
    let room = PlanRules.maxSteps - current.current
    if strict {
      guard cleaned.count <= room else { return .failure(.tooManySteps(max: PlanRules.maxSteps)) }
      guard cleaned.allSatisfy({ $0.count <= PlanRules.maxStepLength }) else {
        return .failure(.stepTooLong(max: PlanRules.maxStepLength))
      }
    } else {
      cleaned = Array(cleaned.prefix(max(1, room)))
    }
    current.steps = Array(current.steps.prefix(current.current)) + cleaned
    current.recentRemarks = []
    current.revision += 1
    if let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
      current.userNotes = Array((current.userNotes + [reason]).suffix(5))
    }
    task = current
    verifier.reset()
    save()
    onEvent?(.planRevised(current, fromStep: fromStep))
    return .success(current)
  }

  /// Something the user told Genio that changes the context ("my model has
  /// no lid"), kept for every later answer.
  public func addUserNote(_ note: String) {
    guard var current = task else { return }
    let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    current.userNotes = Array((current.userNotes + [text]).suffix(5))
    task = current
    save()
  }

  // MARK: - User commands (the user is the authority)

  public func userConfirmedStep() {
    advance(reason: .userConfirmed)
  }

  public func userWentBack() {
    guard var current = task, current.current > 0 || current.finished else { return }
    current.current = max(0, min(current.current, current.steps.count) - 1)
    current.completedAt[current.current] = nil
    current.recentRemarks = []
    current.revision += 1
    task = current
    verifier.reset()
    save()
    onEvent?(.stepChanged(current, reason: .back))
  }

  /// "New task": drops the current one.
  public func clear() {
    guard task != nil else { return }
    task = nil
    paused = false
    observations = []
    verifier.reset()
    save()
    onEvent?(.cleared)
  }

  public func pause() {
    guard task != nil else { return }
    paused = true
    save()
  }

  public func resume() {
    paused = false
    save()
  }

  // MARK: - What the camera shows

  /// A look at the current step (from the coach or the live model). Advances
  /// only when the verifier is convinced.
  @discardableResult
  public func observe(_ observation: StepObservation) -> CompletionVerifier.Outcome {
    guard let current = task else { return .ignored(.stale) }
    remember(observation)
    let outcome = verifier.consider(observation, current: current.current, revision: current.revision, stepCount: current.steps.count)
    if outcome == .confirmed {
      advance(reason: .verified)
    }
    return outcome
  }

  /// A model saying the step looks done. `stepNumber` is 1-based, as the
  /// model sees it; a proposal about another step than the current one is
  /// stale (the conversation moved on) and changes nothing.
  @discardableResult
  public func proposeCompletion(stepNumber: Int, evidence: String, source: ObservationSource) -> CompletionVerifier.Outcome {
    guard let current = task else { return .ignored(.stale) }
    let observation = StepObservation(
      stepIndex: stepNumber - 1, revision: current.revision, verdict: .completed,
      evidence: evidence, source: source, at: now())
    return observe(observation)
  }

  /// Whether a remark is worth saying now, and if so records it. Repeats of
  /// recent remarks and remarks too close to the last one are dropped;
  /// `info` is only remembered.
  public func shouldSay(_ remark: String, kind: RemarkKind) -> Bool {
    let text = remark.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var current = task, !text.isEmpty, kind != .info else { return false }
    let gap = remarkGap[kind] ?? 15
    guard now().timeIntervalSince(lastRemarkAt) >= gap else { return false }
    let normalized = text.lowercased()
    guard !current.recentRemarks.contains(where: { $0.lowercased() == normalized }) else { return false }
    lastRemarkAt = now()
    current.recentRemarks = Array((current.recentRemarks + [text]).suffix(5))
    task = current
    save()
    return true
  }

  // MARK: - State for the models

  /// The task as the models see it (get_task_state, context after a reconnect).
  public func snapshot() -> TaskSnapshot? {
    guard let task else { return nil }
    return TaskSnapshot(task: task, paused: paused, observations: Array(observations.suffix(3)))
  }

  // MARK: - Private

  private func advance(reason: StepChangeReason) {
    guard var current = task, !current.finished else { return }
    current.completedAt[current.current] = now()
    current.current += 1
    current.recentRemarks = []
    current.revision += 1
    task = current
    verifier.reset()
    save()
    if current.finished {
      onEvent?(.finished(current))
    } else {
      onEvent?(.stepChanged(current, reason: reason))
    }
  }

  private func remember(_ observation: StepObservation) {
    observations = Array((observations + [observation]).suffix(memorySize))
  }

  private func save() {
    store?.save(PersistedTaskState(task: task, paused: paused, observations: observations, savedAt: now()))
  }
}

/// The task as handed to a model: plain values, 1-based step numbers.
public struct TaskSnapshot: Codable, Equatable, Sendable {
  public struct Step: Codable, Equatable, Sendable {
    public let number: Int
    public let text: String
    /// "done", "current" or "upcoming".
    public let status: String
  }

  public let goal: String
  public let steps: [Step]
  /// 1-based; steps.count + 1 when finished.
  public let currentStep: Int
  public let totalSteps: Int
  public let finished: Bool
  public let paused: Bool
  public let userNotes: [String]
  public let recentObservations: [String]
  public let recentRemarks: [String]

  init(task: GenioTask, paused: Bool, observations: [StepObservation]) {
    goal = task.goal
    steps = task.steps.enumerated().map { index, text in
      Step(number: index + 1, text: text,
           status: index < task.current ? "done" : (index == task.current ? "current" : "upcoming"))
    }
    currentStep = task.current + 1
    totalSteps = task.steps.count
    finished = task.finished
    self.paused = paused
    userNotes = task.userNotes
    recentObservations = observations.map { "step \($0.stepIndex + 1): \($0.verdict.rawValue) – \($0.evidence)" }
    recentRemarks = task.recentRemarks
  }

  enum CodingKeys: String, CodingKey {
    case goal, steps, finished, paused
    case currentStep = "current_step"
    case totalSteps = "total_steps"
    case userNotes = "user_notes"
    case recentObservations = "recent_observations"
    case recentRemarks = "recent_remarks"
  }

  /// A compact text form, for system instructions and context recovery.
  public var text: String {
    var lines = ["Goal: \(goal)"]
    for step in steps {
      let mark = step.status == "done" ? "[done]" : (step.status == "current" ? "[NOW]" : "[ ]")
      lines.append("\(mark) \(step.number). \(step.text)")
    }
    if finished { lines.append("All steps are done.") }
    if paused { lines.append("(Guidance is paused.)") }
    if !userNotes.isEmpty { lines.append("The user said: " + userNotes.joined(separator: " | ")) }
    if !recentObservations.isEmpty { lines.append("Recent observations: " + recentObservations.joined(separator: " | ")) }
    if !recentRemarks.isEmpty { lines.append("Already told the user (do not repeat): " + recentRemarks.joined(separator: " | ")) }
    return lines.joined(separator: "\n")
  }
}
