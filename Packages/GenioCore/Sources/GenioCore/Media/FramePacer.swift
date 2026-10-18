import Foundation

/// Decides which camera frames go to Gemini Live: at most `framesPerSecond`
/// (capped at 1, the API's limit), only fresh ones, one at a time (a frame
/// still being encoded or sent blocks the next: no queue builds up), and
/// none while paused.
public struct FramePacer: Sendable {
  public enum Decision: Equatable, Sendable {
    case send
    case skip(Reason)
  }

  public enum Reason: String, Equatable, Sendable {
    case paused, tooSoon, busy, stale, noFrame, sameFrame
  }

  public struct Metrics: Equatable, Sendable {
    public var sent = 0
    public var droppedStale = 0
    public var droppedBusy = 0
    public var failed = 0
    /// Average time from the frame's arrival to the end of its send.
    public var averageLatency: TimeInterval = 0
    public var lastSentAt: Date?
  }

  public var framesPerSecond: Double {
    didSet { framesPerSecond = min(1, max(0.1, framesPerSecond)) }
  }
  /// Older frames are not worth sending (the glasses were taken off).
  public var maxFrameAge: TimeInterval
  public var paused = false
  public private(set) var metrics = Metrics()

  private var inFlight = false
  private var lastFrameTime: Date?

  public init(framesPerSecond: Double = 1, maxFrameAge: TimeInterval = 1.5) {
    self.framesPerSecond = min(1, max(0.1, framesPerSecond))
    self.maxFrameAge = maxFrameAge
  }

  public var interval: TimeInterval { 1 / framesPerSecond }

  /// Whether to take the frame that arrived at `frameTime`. On `.send` the
  /// pacer counts it in flight until `finished` is called.
  public mutating func decide(frameTime: Date?, now: Date) -> Decision {
    if paused { return .skip(.paused) }
    guard let frameTime else { return .skip(.noFrame) }
    if inFlight {
      metrics.droppedBusy += 1
      return .skip(.busy)
    }
    if let last = metrics.lastSentAt, now.timeIntervalSince(last) < interval { return .skip(.tooSoon) }
    if frameTime == lastFrameTime { return .skip(.sameFrame) }
    if now.timeIntervalSince(frameTime) > maxFrameAge {
      metrics.droppedStale += 1
      return .skip(.stale)
    }
    inFlight = true
    lastFrameTime = frameTime
    return .send
  }

  /// The frame taken at `frameTime` was sent (or failed) at `now`.
  public mutating func finished(frameTime: Date, now: Date, sent: Bool) {
    inFlight = false
    guard sent else {
      metrics.failed += 1
      return
    }
    let latency = now.timeIntervalSince(frameTime)
    metrics.averageLatency = metrics.sent == 0 ? latency : metrics.averageLatency * 0.8 + latency * 0.2
    metrics.sent += 1
    metrics.lastSentAt = now
  }

  public mutating func resetMetrics() {
    metrics = Metrics()
  }
}
