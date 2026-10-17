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

  static func plan(request: String) -> String {
    """
    The user, wearing smart glasses with a camera, asked: "\(request)"
    Turn it into 3 to 12 short, concrete steps they can follow one at a time with their hands busy.
    Each step one sentence, in \(language). goal: a 2-5 word title in \(language).
    If an image is attached, it is what the user is looking at: use it.
    """
  }

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

/// Uses `primary`; when it cannot answer for a reason that is not the
/// question's fault (not signed in, usage limit, provider down), asks
/// `backup` instead. Lets ChatGPT run on the plan and Claude cover the gaps.
struct FallbackBrain: Brain {
  let primary: any Brain
  let backup: any Brain

  func coach(image: Data, goal: String, steps: [String], current: Int, recentRemarks: [String]) async throws -> CoachVerdict {
    do {
      return try await primary.coach(image: image, goal: goal, steps: steps, current: current, recentRemarks: recentRemarks)
    } catch where Self.shouldFallBack(error) {
      return try await backup.coach(image: image, goal: goal, steps: steps, current: current, recentRemarks: recentRemarks)
    }
  }

  func plan(request: String, image: Data?) async throws -> Plan {
    do {
      return try await primary.plan(request: request, image: image)
    } catch where Self.shouldFallBack(error) {
      return try await backup.plan(request: request, image: image)
    }
  }

  func answer(question: String, image: Data?, taskContext: String?) async throws -> String {
    do {
      return try await primary.answer(question: question, image: image, taskContext: taskContext)
    } catch where Self.shouldFallBack(error) {
      return try await backup.answer(question: question, image: image, taskContext: taskContext)
    }
  }

  private static func shouldFallBack(_ error: Error) -> Bool {
    guard let brainError = error as? BrainError else { return error is URLError }
    switch brainError {
    case .notSignedIn, .usageLimit: return true
    case .http(_, let code, _): return code == 401 || code == 403 || code == 429 || code >= 500
    case .noKey, .refused, .badResponse: return false
    }
  }
}
