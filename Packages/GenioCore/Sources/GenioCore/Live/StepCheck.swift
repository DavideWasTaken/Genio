import Foundation

/// When the app asks Gemini Live to look at the current step on its own,
/// without waiting for the user to speak.
///
/// Gemini Live answers only to input: frames alone never make it speak, so a
/// user who finishes a step in silence would wait forever. Every `interval`
/// seconds of quiet, while a step is in progress and the camera is on, the
/// app sends a check ("is step N done?"). A new step restarts the clock, and
/// nobody is interrupted: no check within `quietAfterSpeech` of anyone
/// speaking.
public struct StepCheckPolicy: Sendable {
  public var interval: TimeInterval
  public var quietAfterSpeech: TimeInterval
  private var lastCheck: Date?
  private var stepKey: StepKey?

  private struct StepKey: Equatable, Sendable {
    let step: Int
    let revision: Int
  }

  public init(interval: TimeInterval = 10, quietAfterSpeech: TimeInterval = 4) {
    self.interval = interval
    self.quietAfterSpeech = quietAfterSpeech
  }

  /// True when a check is due now (and counts it as sent).
  /// `step`: the current step index and task revision, nil if there is no
  /// step to check (no task, finished, paused). `lastSpeech`: when the user
  /// or Genio last spoke.
  public mutating func shouldCheck(now: Date, step: (index: Int, revision: Int)?, cameraOn: Bool, lastSpeech: Date?) -> Bool {
    guard let step, cameraOn else {
      stepKey = nil
      return false
    }
    let key = StepKey(step: step.index, revision: step.revision)
    if key != stepKey {
      // A new step (or the camera just came on): give the user time first.
      stepKey = key
      lastCheck = now
      return false
    }
    if let lastSpeech, now.timeIntervalSince(lastSpeech) < quietAfterSpeech { return false }
    if let lastCheck, now.timeIntervalSince(lastCheck) < interval { return false }
    lastCheck = now
    return true
  }
}
