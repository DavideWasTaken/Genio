import Foundation

/// A hands-on task split into steps, and where the user is in it.
///
/// `revision` changes whenever the current step or the remaining steps
/// change: anything computed for an older revision (a coach verdict, a
/// model's proposal) is about a step that is gone and must be dropped.
public struct GenioTask: Equatable, Codable, Sendable {
  public var id = UUID()
  public let goal: String
  public var steps: [String]
  public var current = 0
  public var recentRemarks: [String] = []
  public var revision = 0
  /// When each finished step was completed, by index.
  public var completedAt: [Int: Date] = [:]
  /// Changes the user asked for ("I have a different model"), newest last.
  public var userNotes: [String] = []
  public var createdAt = Date()

  public init(goal: String, steps: [String]) {
    self.goal = goal
    self.steps = steps
  }

  public var finished: Bool { current >= steps.count }
  public var currentStep: String? { finished ? nil : steps[current] }

  public var summary: String {
    finished ? "Ha finito: \(goal)." : "\(goal), passo \(current + 1) di \(steps.count): \(steps[current])"
  }
}

/// Limits every plan must respect, whoever proposes it.
public enum PlanRules {
  public static let minSteps = 3
  public static let maxSteps = 12
  public static let maxStepLength = 300
  public static let maxGoalLength = 80

  /// Trimmed, non-empty steps, or nil.
  public static func clean(_ steps: [String]) -> [String] {
    steps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
  }
}
