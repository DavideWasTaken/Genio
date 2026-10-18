import Foundation

/// What one look at the camera says about the current step.
public enum StepVerdict: String, Codable, Sendable, CaseIterable {
  /// The frame clearly shows the step finished.
  case completed
  /// The frame clearly shows the step is not finished (or undone).
  case notCompleted = "not_completed"
  /// The step is in view but the frame does not settle it.
  case uncertain
  /// The frame does not show what the step is about (looking away, blurred,
  /// too dark, hands in the way).
  case noView = "no_view"
}

/// Who looked.
public enum ObservationSource: String, Codable, Sendable {
  /// The periodic vision coach (Claude / ChatGPT).
  case coach
  /// The Gemini Live conversation model, through a tool call.
  case live
}

/// One look at one step: what was seen, by whom, about which revision.
public struct StepObservation: Equatable, Codable, Sendable {
  public let stepIndex: Int
  public let revision: Int
  public let verdict: StepVerdict
  /// What in the frame supports the verdict ("the four screws are out and on
  /// the table"). A completion without evidence does not count.
  public let evidence: String
  public let source: ObservationSource
  public let at: Date

  public init(stepIndex: Int, revision: Int, verdict: StepVerdict, evidence: String, source: ObservationSource, at: Date) {
    self.stepIndex = stepIndex
    self.revision = revision
    self.verdict = verdict
    self.evidence = evidence
    self.source = source
    self.at = at
  }
}

/// Decides when the camera has really shown a step finished. One look is
/// never enough: false completions (skipping a step the user has not done)
/// are worse than a late one, so the rule is
///
///  - only `completed` looks with explicit evidence count;
///  - they must be about the current step and revision (older ones are stale);
///  - it takes `requiredConfirmations` of them, at least `minSpacing` apart
///    (two looks at the same instant are one look), within `window`;
///  - a `notCompleted` look cancels the confirmations gathered so far;
///  - `uncertain` and `noView` neither count nor cancel.
///
/// The user saying "done" bypasses this: the user is the authority.
public struct CompletionVerifier: Sendable {
  public enum Outcome: Equatable, Sendable {
    /// Enough consistent evidence: the step is done.
    case confirmed
    /// Counted; `have` of `need` confirmations so far.
    case pending(have: Int, need: Int)
    /// Not counted, and why.
    case ignored(Reason)
    /// A clear "not done" cleared the confirmations.
    case reset
  }

  public enum Reason: String, Equatable, Sendable {
    case stale, noEvidence, uncertain, noView, tooSoon, finished
  }

  public var requiredConfirmations: Int
  public var minSpacing: TimeInterval
  public var window: TimeInterval

  private var confirmations: [StepObservation] = []
  private var key: (step: Int, revision: Int)?

  public init(requiredConfirmations: Int = 2, minSpacing: TimeInterval = 2, window: TimeInterval = 45) {
    self.requiredConfirmations = max(1, requiredConfirmations)
    self.minSpacing = minSpacing
    self.window = window
  }

  /// Counted confirmations for the current step (for diagnostics and the UI).
  public var pendingCount: Int { confirmations.count }

  public mutating func reset() {
    confirmations = []
    key = nil
  }

  /// Weighs one observation of the task as it is now.
  public mutating func consider(_ observation: StepObservation, current: Int, revision: Int, stepCount: Int) -> Outcome {
    guard current < stepCount else { return .ignored(.finished) }
    guard observation.stepIndex == current, observation.revision == revision else { return .ignored(.stale) }
    if key == nil || key! != (current, revision) {
      confirmations = []
      key = (current, revision)
    }
    switch observation.verdict {
    case .uncertain:
      return .ignored(.uncertain)
    case .noView:
      return .ignored(.noView)
    case .notCompleted:
      let hadAny = !confirmations.isEmpty
      confirmations = []
      return hadAny ? .reset : .ignored(.uncertain)
    case .completed:
      guard !observation.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return .ignored(.noEvidence)
      }
      confirmations.removeAll { observation.at.timeIntervalSince($0.at) > window }
      if let last = confirmations.last, observation.at.timeIntervalSince(last.at) < minSpacing {
        return .ignored(.tooSoon)
      }
      confirmations.append(observation)
      if confirmations.count >= requiredConfirmations {
        confirmations = []
        return .confirmed
      }
      return .pending(have: confirmations.count, need: requiredConfirmations)
    }
  }
}
