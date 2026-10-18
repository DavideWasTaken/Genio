import Foundation

/// What is saved between launches: the task and what was seen of it.
public struct PersistedTaskState: Codable, Equatable, Sendable {
  public var task: GenioTask?
  public var paused: Bool
  public var observations: [StepObservation]
  public var savedAt: Date

  public init(task: GenioTask?, paused: Bool, observations: [StepObservation], savedAt: Date) {
    self.task = task
    self.paused = paused
    self.observations = observations
    self.savedAt = savedAt
  }
}

/// Where the task engine keeps its state.
public protocol TaskStore: AnyObject {
  func load() -> PersistedTaskState?
  func save(_ state: PersistedTaskState)
}

/// A JSON file (Application Support/Genio/task.json by default), written
/// atomically so a crash mid-write leaves the previous version.
public final class FileTaskStore: TaskStore {
  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  public static func standard() -> FileTaskStore {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return FileTaskStore(url: base.appendingPathComponent("Genio", isDirectory: true).appendingPathComponent("task.json"))
  }

  public func load() -> PersistedTaskState? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(PersistedTaskState.self, from: data)
  }

  public func save(_ state: PersistedTaskState) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(state) else { return }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    #if os(iOS)
    try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    #else
    try? data.write(to: url, options: [.atomic])
    #endif
  }
}

/// Keeps state in memory only (tests, previews).
public final class MemoryTaskStore: TaskStore {
  public var state: PersistedTaskState?
  public private(set) var saveCount = 0

  public init(state: PersistedTaskState? = nil) {
    self.state = state
  }

  public func load() -> PersistedTaskState? { state }

  public func save(_ state: PersistedTaskState) {
    self.state = state
    saveCount += 1
  }
}
