import Foundation

/// What Genio needs from a model, whichever provider answers:
///  - coach:  looks at a camera frame every few seconds and says whether the
///            current step is done, or warns about a mistake or hazard.
///  - plan:   turns what you asked for into short, concrete steps.
///  - answer: quick spoken answers to "Genio, ..." questions, with what you see.
protocol Brain: Sendable {
  func coach(image: Data, goal: String, steps: [String], current: Int, recentRemarks: [String]) async throws -> CoachVerdict
  func plan(request: String, image: Data?) async throws -> Plan
  func answer(question: String, image: Data?, taskContext: String?) async throws -> String
  /// Something the user said while being guided: a reply to speak and,
  /// when the plan does not fit what they have in front of them, the
  /// corrected steps from the current one to the end.
  func followUp(message: String, image: Data?, goal: String, steps: [String], current: Int) async throws -> FollowUp
}

struct FollowUp: Decodable {
  let say: String
  /// Replaces the steps from the current one on; empty when the plan stands.
  let remainingSteps: [String]

  enum CodingKeys: String, CodingKey {
    case say
    case remainingSteps = "remaining_steps"
  }
}

struct CoachVerdict: Decodable {
  let stepDone: Bool
  let say: String

  enum CodingKeys: String, CodingKey {
    case stepDone = "step_done"
    case say
  }
}

struct Plan: Decodable {
  let goal: String
  let steps: [String]
}

enum BrainError: LocalizedError {
  case noKey
  case notSignedIn
  case http(String, Int, String)
  /// The ChatGPT plan's usage limit was reached (Plus: a 5-hour window shared
  /// by every app using the plan).
  case usageLimit
  case refused
  case badResponse

  /// No key or no sign-in: this brain was never set up.
  var isNotConfigured: Bool {
    switch self {
    case .noKey, .notSignedIn: return true
    default: return false
    }
  }

  var errorDescription: String? {
    switch self {
    case .noKey: return String(localized: "The Claude API key is missing (Settings).")
    case .notSignedIn: return String(localized: "Sign in with ChatGPT in Settings.")
    case .http(let provider, let code, let message): return "\(provider) \(code): \(message)"
    case .usageLimit: return String(localized: "ChatGPT plan usage limit reached.")
    case .refused: return String(localized: "The model declined the request.")
    case .badResponse: return String(localized: "The model's answer was not valid.")
    }
  }
}

/// The prompts and JSON schemas, shared by every provider so Claude and
/// ChatGPT are asked exactly the same thing.
enum Prompts {
  /// The voice language (Settings): what the model must answer in.
  static var language: String { VoiceLanguage.current.promptName }

  static let coachInstructions =
    "You watch a live camera feed from smart glasses while the user does a hands-on task, and coach them sparingly."

  static func coach(goal: String, steps: [String], current: Int, recentRemarks: [String]) -> String {
    let numbered = steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    return """
      Goal: \(goal)
      Steps:
      \(numbered)
      The user is on step \(current + 1): "\(steps[current])".
      Your recent remarks (do not repeat them): \(recentRemarks.suffix(3).joined(separator: " | "))

      Look at the camera frame and answer:
      - step_done: true only if the frame clearly shows step \(current + 1) is finished.
      - say: one short sentence in \(language) to say NOW, or "" if nothing is worth saying.
        Speak only for a clear mistake or a hazard (heat, blade, spill, wrong part).
        If unsure, return "". Silence is the default.
      """
  }

  static let coachSchema: [String: Any] = [
    "type": "object",
    "properties": [
      "step_done": ["type": "boolean"],
      "say": ["type": "string"],
    ],
    "required": ["step_done", "say"],
    "additionalProperties": false,
  ]

  static let planInstructions = "You plan hands-on tasks as short spoken steps."

  static func plan(request: String, hasImage: Bool) -> String {
    let seeing = hasImage
      ? "The attached image is what the user is looking at right now: base the steps on what you see (device, brand, layout, tools)."
      : "You cannot see what the user is looking at right now. Do not assume details you cannot know, such as the operating system, brand or layout: keep the steps neutral, or make the first step a quick check (for example asking which system they are on)."
    return """
      The user, wearing smart glasses with a camera, asked: "\(request)"
      Turn it into 3 to 12 short, concrete steps they can follow one at a time with their hands busy.
      Each step one sentence, in \(language). goal: a 2-5 word title in \(language).
      \(seeing)
      """
  }

  static let followUpInstructions =
    "You are Genio, a voice coach in the user's smart glasses, guiding a hands-on task one step at a time."

  static func followUp(message: String, hasImage: Bool, goal: String, steps: [String], current: Int) -> String {
    let list = steps.enumerated().map { index, step in
      "\(index < current ? "done" : (index == current ? "NOW" : "next")) \(index + 1). \(step)"
    }.joined(separator: "\n")
    let seeing = hasImage
      ? "The attached image is what they are looking at right now."
      : "You cannot see what they are looking at right now."
    return """
      The user is doing: \(goal)
      Steps:
      \(list)
      They just said: "\(message)"
      \(seeing)

      Answer in JSON:
      - say: what to tell them now, in \(language), one to three short spoken sentences: answer them, clarify, or correct the current step using what you see.
      - remaining_steps: if their situation differs from the plan (another device or system, a missing tool, a step that does not apply), the corrected steps from step \(current + 1) to the end, each one short sentence in \(language). Otherwise [].
      If they are clearly talking to someone else and not to you, return say "" and remaining_steps [].
      """
  }

  static let followUpSchema: [String: Any] = [
    "type": "object",
    "properties": [
      "say": ["type": "string"],
      "remaining_steps": ["type": "array", "items": ["type": "string"]],
    ],
    "required": ["say", "remaining_steps"],
    "additionalProperties": false,
  ]

  static let planSchema: [String: Any] = [
    "type": "object",
    "properties": [
      "goal": ["type": "string"],
      "steps": ["type": "array", "items": ["type": "string"]],
    ],
    "required": ["goal", "steps"],
    "additionalProperties": false,
  ]

  static let answerInstructions = """
    You are Genio, a voice assistant in the user's smart glasses. Your answer is read aloud: \
    answer in \(language), in one to three short sentences, plain words, no lists, no markdown. \
    If the question is about what they see, use the image.
    """

  static func answer(question: String, hasImage: Bool, taskContext: String?) -> String {
    var prompt = "Question: \(question)"
    if let taskContext { prompt += "\n\nWhat the user is doing: \(taskContext)" }
    if hasImage { prompt += "\n\nThe attached image is what the user is looking at right now." }
    return prompt
  }

  static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
    guard let data = text.data(using: .utf8),
          let value = try? JSONDecoder().decode(type, from: data)
    else { throw BrainError.badResponse }
    return value
  }
}

/// The main brain with the other one as backup, in either direction
/// (Settings → Model and accounts → "Use the other as backup"). When the
/// main one cannot answer for a reason that is not the question's fault (no
/// key or sign-in, credit or plan limit used up, service down), the backup
/// answers instead. If the backup is not set up either, the main one's
/// error is what the user hears about.
struct FallbackBrain: Brain {
  let primary: any Brain
  let backup: any Brain

  func coach(image: Data, goal: String, steps: [String], current: Int, recentRemarks: [String]) async throws -> CoachVerdict {
    try await run { try await $0.coach(image: image, goal: goal, steps: steps, current: current, recentRemarks: recentRemarks) }
  }

  func plan(request: String, image: Data?) async throws -> Plan {
    try await run { try await $0.plan(request: request, image: image) }
  }

  func answer(question: String, image: Data?, taskContext: String?) async throws -> String {
    try await run { try await $0.answer(question: question, image: image, taskContext: taskContext) }
  }

  func followUp(message: String, image: Data?, goal: String, steps: [String], current: Int) async throws -> FollowUp {
    try await run { try await $0.followUp(message: message, image: image, goal: goal, steps: steps, current: current) }
  }

  private func run<T>(_ call: (any Brain) async throws -> T) async throws -> T {
    do {
      return try await call(primary)
    } catch where Self.shouldFallBack(error) {
      GenioLog.post("Brain: main one unavailable (\(error.localizedDescription)), asking the backup")
      do {
        return try await call(backup)
      } catch let backupError as BrainError where backupError.isNotConfigured {
        throw error
      }
    }
  }

  private static func shouldFallBack(_ error: Error) -> Bool {
    guard let brainError = error as? BrainError else { return error is URLError }
    switch brainError {
    case .noKey, .notSignedIn, .usageLimit:
      return true
    case .http(_, let code, let message):
      // Anthropic reports a used-up credit balance as a 400.
      return code == 401 || code == 402 || code == 403 || code == 429 || code >= 500
        || message.localizedCaseInsensitiveContains("credit")
    case .refused, .badResponse:
      return false
    }
  }
}
