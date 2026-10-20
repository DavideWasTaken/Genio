import Foundation

/// Makes sure a warning is actually heard, not just sent.
///
/// A remark the engine let through (a hazard or a mistake the coach saw, or
/// one Gemini reported itself) is recorded as said, so it is never proposed
/// again for that step. If it then gets lost (sent while the user was
/// talking, cut off by an interruption, or answered with something else),
/// the user never hears it. So the app keeps it here until Genio's own words
/// show it was said:
///
///  - it is sent only when nobody is talking (a hazard after a shorter quiet);
///  - the next turn Genio finishes is checked against it: the remark's key
///    words (the object, the part) must be in what Genio said;
///  - an interrupted turn, a turn about something else, or no answer in time
///    counts as not heard: it is sent once more, then given up;
///  - it expires (a warning about something seen half a minute ago only
///    confuses), and a mistake is dropped when the step changes (a hazard
///    stays: the hot pan is still hot).
public struct RemarkDelivery: Sendable {
  /// The step a remark is about: its index and the task revision.
  public struct StepRef: Equatable, Sendable {
    public let index: Int
    public let revision: Int

    public init(index: Int, revision: Int) {
      self.index = index
      self.revision = revision
    }
  }

  public struct Remark: Equatable, Sendable {
    public let text: String
    public let kind: RemarkKind
    public let step: StepRef?
    public let queuedAt: Date
    /// Times it was sent (or said by Gemini on its own).
    public fileprivate(set) var attempts = 0
    /// When the last attempt went out; nil while waiting to be sent.
    public fileprivate(set) var sentAt: Date?
  }

  public enum Event: Equatable, Sendable {
    /// Send this to Gemini now; `retry` when the first attempt was not heard.
    case send(Remark, retry: Bool)
    case delivered(Remark)
    case dropped(Remark, reason: DropReason)
  }

  public enum DropReason: String, Sendable {
    /// Sent the maximum number of times, never heard.
    case notHeard = "not heard"
    case expired
    /// A mistake about a step that is no longer current.
    case stepChanged = "step changed"
  }

  /// Attempts before giving up (the first one included).
  public var maxAttempts = 2
  /// How long a remark stays worth saying, from when it was seen.
  public var lifetime: [RemarkKind: TimeInterval] = [.hazard: 30, .mistake: 25, .info: 20]
  /// How long Genio has to say a sent remark.
  public var answerTimeout: TimeInterval = 10
  /// Quiet needed after the user spoke before sending (a hazard waits less).
  public var quietAfterUser: [RemarkKind: TimeInterval] = [.hazard: 1, .mistake: 2.5, .info: 2.5]

  /// Waiting or in flight, hazards first.
  public private(set) var pending: [Remark] = []

  public init() {}

  /// Nothing to send and nothing waiting to be heard.
  public var isIdle: Bool { pending.isEmpty }

  /// A remark the app will send (from the vision coach).
  public mutating func queue(_ text: String, kind: RemarkKind, step: StepRef?, now: Date) {
    add(text, kind: kind, step: step, now: now, alreadySent: false)
  }

  /// A remark Gemini is about to say on its own (report_observation said
  /// speak): watched like a sent one, and sent again if it is not heard.
  public mutating func expect(_ text: String, kind: RemarkKind, step: StepRef?, now: Date) {
    add(text, kind: kind, step: step, now: now, alreadySent: true)
  }

  private mutating func add(_ text: String, kind: RemarkKind, step: StepRef?, now: Date, alreadySent: Bool) {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !pending.contains(where: { $0.text.lowercased() == text.lowercased() }) else { return }
    var remark = Remark(text: text, kind: kind, step: step, queuedAt: now)
    if alreadySent {
      remark.attempts = 1
      remark.sentAt = now
    }
    pending.append(remark)
    pending.sort { Self.rank($0.kind) < Self.rank($1.kind) }
  }

  /// Called on every tick. `step`: the current step (nil: none). `canSpeak`:
  /// Genio is not speaking, not busy with a call, and the camera is not
  /// being announced. `lastUserSpeech`: when the user last spoke.
  public mutating func tick(now: Date, step: StepRef?, canSpeak: Bool, lastUserSpeech: Date?) -> [Event] {
    var events: [Event] = []
    var kept: [Remark] = []
    for var remark in pending {
      if now.timeIntervalSince(remark.queuedAt) > (lifetime[remark.kind] ?? 20) {
        events.append(.dropped(remark, reason: .expired))
        continue
      }
      if remark.kind != .hazard, remark.step != nil, remark.step != step {
        events.append(.dropped(remark, reason: .stepChanged))
        continue
      }
      if let sentAt = remark.sentAt, now.timeIntervalSince(sentAt) > answerTimeout {
        // Genio never said it.
        remark.sentAt = nil
        if remark.attempts >= maxAttempts {
          events.append(.dropped(remark, reason: .notHeard))
          continue
        }
      }
      kept.append(remark)
    }
    pending = kept
    // One remark in the air at a time.
    guard canSpeak, !pending.contains(where: { $0.sentAt != nil }),
          let index = pending.firstIndex(where: { $0.sentAt == nil })
    else { return events }
    let quiet = quietAfterUser[pending[index].kind] ?? 2.5
    if let lastUserSpeech, now.timeIntervalSince(lastUserSpeech) < quiet { return events }
    pending[index].attempts += 1
    pending[index].sentAt = now
    events.append(.send(pending[index], retry: pending[index].attempts > 1))
    return events
  }

  /// Genio finished a turn (`transcript`: what it said in it). A remark in
  /// flight is heard if its key words are there; otherwise Genio answered
  /// something else, and the remark goes out again (or is given up).
  public mutating func genioFinishedTurn(_ transcript: String, now: Date) -> [Event] {
    guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
    var events: [Event] = []
    var kept: [Remark] = []
    for var remark in pending {
      guard let sentAt = remark.sentAt, sentAt <= now else {
        kept.append(remark)
        continue
      }
      if Self.said(remark.text, in: transcript) {
        events.append(.delivered(remark))
        continue
      }
      remark.sentAt = nil
      if remark.attempts >= maxAttempts {
        events.append(.dropped(remark, reason: .notHeard))
      } else {
        kept.append(remark)
      }
    }
    pending = kept
    return events
  }

  /// The user cut Genio off: a remark in flight was not heard (its words may
  /// have been generated, but not played).
  public mutating func genioInterrupted(now: Date) -> [Event] {
    var events: [Event] = []
    var kept: [Remark] = []
    for var remark in pending {
      guard let sentAt = remark.sentAt, sentAt <= now else {
        kept.append(remark)
        continue
      }
      remark.sentAt = nil
      if remark.attempts >= maxAttempts {
        events.append(.dropped(remark, reason: .notHeard))
      } else {
        kept.append(remark)
      }
    }
    pending = kept
    return events
  }

  public mutating func reset() {
    pending = []
  }

  private static func rank(_ kind: RemarkKind) -> Int {
    switch kind {
    case .hazard: return 0
    case .mistake: return 1
    case .info: return 2
    }
  }

  // MARK: - Matching

  /// Whether `transcript` says `remark`: at least one of its key words, and
  /// a third of them, appear there. Words are compared by their first five
  /// letters, so "calda" matches "caldo" and "stringi" matches "stringere";
  /// accents and case are ignored. A remark with no key words counts as said
  /// by any real sentence.
  public static func said(_ remark: String, in transcript: String) -> Bool {
    let keys = Set(keyWords(remark))
    let heard = Set(normalized(transcript).map(stem))
    guard !keys.isEmpty else { return heard.count >= 2 }
    let found = keys.filter(heard.contains).count
    return found >= 1 && Double(found) / Double(keys.count) >= 1.0 / 3.0
  }

  static func keyWords(_ text: String) -> [String] {
    normalized(text).filter { $0.count >= 4 && !fillers.contains($0) }.map(stem)
  }

  private static func normalized(_ text: String) -> [String] {
    TaskTools.normalizedWords(text).map { $0.lowercased() }
  }

  private static func stem(_ word: String) -> String {
    String(word.prefix(5))
  }

  /// Words every warning may use, which say nothing about what it is about.
  private static let fillers: Set<String> = [
    // Italian
    "attento", "attenta", "attenti", "attenzione", "occhio", "controlla", "verifica", "guarda", "sembra",
    "forse", "questo", "questa", "quello", "quella", "sono", "molto", "prima", "dopo", "ancora", "fermo",
    "ferma", "fermati", "aspetta", "bene", "meglio", "proprio", "stai", "hai", "della", "dello", "delle",
    "degli", "nella", "nello", "sulla", "sullo", "alla", "allo", "come", "perche",
    // English
    "careful", "watch", "check", "look", "looks", "seems", "maybe", "this", "that", "these", "those",
    "your", "with", "before", "after", "still", "wait", "stop", "make", "sure", "there", "here", "very",
    "please", "might", "could", "should", "about",
  ]
}
