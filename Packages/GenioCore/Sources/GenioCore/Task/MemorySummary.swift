import Foundation

/// What Genio remembers beyond the task in progress: facts about the user
/// and earlier tasks that can be resumed.
public struct MemorySummary: Codable, Equatable, Sendable {
  public struct SavedTask: Codable, Equatable, Sendable {
    /// The first 8 characters of the task's id: what resume_task takes.
    public let id: String
    public let goal: String
    /// "step 3 of 7".
    public let progress: String
    public let lastUsed: Date?

    public init(_ task: GenioTask) {
      id = String(task.id.uuidString.prefix(8)).lowercased()
      goal = task.goal
      progress = "step \(min(task.current + 1, task.steps.count)) of \(task.steps.count)"
      lastUsed = task.updatedAt
    }

    enum CodingKeys: String, CodingKey {
      case id = "task_id"
      case goal, progress
      case lastUsed = "last_used"
    }
  }

  public let facts: [String]
  public let savedTasks: [SavedTask]

  public init(facts: [String], savedTasks: [SavedTask]) {
    self.facts = facts
    self.savedTasks = savedTasks
  }

  public var isEmpty: Bool { facts.isEmpty && savedTasks.isEmpty }

  enum CodingKeys: String, CodingKey {
    case facts
    case savedTasks = "saved_tasks"
  }

  /// For the system instruction.
  public var text: String {
    var lines: [String] = []
    if !facts.isEmpty { lines.append("What you know about the user: " + facts.joined(separator: " | ")) }
    if !savedTasks.isEmpty {
      lines.append("Unfinished earlier tasks (resume_task can pick one up): "
        + savedTasks.map { "\($0.goal) (\($0.progress), id \($0.id))" }.joined(separator: " | "))
    }
    return lines.joined(separator: "\n")
  }
}
