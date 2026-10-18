import Foundation

/// One look at the current step by the vision coach.
public struct CoachVerdict: Equatable, Sendable, Decodable {
  public let verdict: StepVerdict
  /// What in the frame supports the verdict.
  public let evidence: String
  /// A sentence to say now, or "".
  public let say: String
  public let kind: RemarkKind

  public init(verdict: StepVerdict, evidence: String, say: String, kind: RemarkKind) {
    self.verdict = verdict
    self.evidence = evidence
    self.say = say
    self.kind = kind
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    verdict = (try? container.decode(StepVerdict.self, forKey: .verdict)) ?? .uncertain
    evidence = try container.decodeIfPresent(String.self, forKey: .evidence) ?? ""
    say = try container.decodeIfPresent(String.self, forKey: .say) ?? ""
    kind = (try? container.decode(RemarkKind.self, forKey: .kind)) ?? .info
  }

  enum CodingKeys: String, CodingKey { case verdict, evidence, say, kind }
}

public enum GeminiError: Error, Equatable, LocalizedError {
  case noKey
  case http(Int, String)
  case badResponse
  /// The answer was withheld (safety filters, recitation).
  case blocked(String)

  public var errorDescription: String? {
    switch self {
    case .noKey: return "The Gemini API key is missing."
    case .http(let code, let message): return "Gemini \(code): \(message)"
    case .badResponse: return "Gemini's answer was not valid."
    case .blocked(let reason): return "Gemini withheld the answer (\(reason))."
    }
  }
}

/// HTTP, abstracted for tests.
public protocol HTTPTransport: Sendable {
  func send(_ request: URLRequest) async throws -> (Data, Int)
}

public struct URLSessionTransport: HTTPTransport {
  public init() {}

  public func send(_ request: URLRequest) async throws -> (Data, Int) {
    let (data, response) = try await URLSession.shared.data(for: request)
    return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
  }
}

/// The periodic vision coach on a Gemini model through generateContent
/// (REST), independent of the Live conversation: same API key, its own
/// model (a fast "flash" model by default), structured JSON output.
public struct GeminiVisionCoach: Sendable {
  public static let base = "https://generativelanguage.googleapis.com/v1beta"
  /// Used when the model list cannot be read.
  public static let fallbackModel = "gemini-flash-latest"

  public let apiKey: String
  public let model: String
  public let languageName: String
  public let transport: HTTPTransport

  public init(apiKey: String, model: String, languageName: String, transport: HTTPTransport = URLSessionTransport()) {
    self.apiKey = apiKey
    self.model = model
    self.languageName = languageName
    self.transport = transport
  }

  public func coach(image: Data, goal: String, steps: [String], current: Int, recentRemarks: [String]) async throws -> CoachVerdict {
    guard !apiKey.isEmpty else { throw GeminiError.noKey }
    let request = try Self.request(
      apiKey: apiKey, model: model, image: image,
      prompt: Self.prompt(goal: goal, steps: steps, current: current, recentRemarks: recentRemarks, language: languageName))
    let (data, status) = try await transport.send(request)
    guard (200..<300).contains(status) else { throw GeminiError.http(status, Self.errorMessage(data)) }
    return try Self.parse(data)
  }

  // MARK: - Wire format (testable)

  public static let instructions =
    "You watch a live camera feed from smart glasses while the user does a hands-on task, and coach them sparingly."

  public static func prompt(goal: String, steps: [String], current: Int, recentRemarks: [String], language: String) -> String {
    let numbered = steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    return """
      Goal: \(goal)
      Steps:
      \(numbered)
      The user is on step \(current + 1): "\(steps[current])".
      Your recent remarks (do not repeat them): \(recentRemarks.suffix(3).joined(separator: " | "))

      Look at the camera frame and answer:
      - verdict about step \(current + 1):
        "completed" only if the frame clearly shows it finished;
        "not_completed" if it clearly shows it is not done (or was undone);
        "uncertain" if the step is in view but the frame does not settle it;
        "no_view" if the frame does not show what the step is about (looking away, dark, blurred, hands in the way).
        When in doubt, "uncertain". A wrong "completed" makes the user skip a step: avoid it.
      - evidence: what exactly in the frame supports the verdict (required for "completed").
      - say: one short sentence in \(language) to say NOW, or "" if nothing is worth saying.
        Speak only for a clear mistake or a hazard (heat, blade, spill, wrong part), cautiously ("careful, check that…").
        If unsure, return "". Silence is the default.
      - kind: "hazard", "mistake", or "info" (anything else).
      """
  }

  static var responseSchema: [String: Any] {
    Schema.object(properties: [
      ("verdict", .string(description: "What the frame shows about the current step.", enumValues: StepVerdict.allCases.map(\.rawValue))),
      ("evidence", .string(description: "What in the frame supports the verdict.")),
      ("say", .string(description: "One short sentence to say now, or empty.")),
      ("kind", .string(description: "What a remark is about.", enumValues: RemarkKind.allCases.map(\.rawValue))),
    ], required: ["verdict", "evidence", "say", "kind"]).json
  }

  public static func request(apiKey: String, model: String, image: Data, prompt: String) throws -> URLRequest {
    let name = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
    guard let url = URL(string: "\(base)/models/\(name):generateContent") else { throw GeminiError.badResponse }
    let body: [String: Any] = [
      "systemInstruction": ["parts": [["text": instructions]]],
      "contents": [[
        "role": "user",
        "parts": [
          ["inlineData": ["mimeType": "image/jpeg", "data": image.base64EncodedString()]],
          ["text": prompt],
        ],
      ]],
      "generationConfig": [
        "responseMimeType": "application/json",
        "responseSchema": responseSchema,
        "temperature": 0.2,
      ],
    ]
    var request = URLRequest(url: url, timeoutInterval: 20)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return request
  }

  public static func parse(_ data: Data) throws -> CoachVerdict {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw GeminiError.badResponse }
    guard let candidate = (root["candidates"] as? [[String: Any]])?.first else {
      let reason = ((root["promptFeedback"] as? [String: Any])?["blockReason"] as? String) ?? "no candidates"
      throw GeminiError.blocked(reason)
    }
    let parts = ((candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
    var text = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("```") {  // a fenced answer despite the JSON mime type
      text = text.split(separator: "\n").dropFirst().filter { !$0.hasPrefix("```") }.joined(separator: "\n")
    }
    guard !text.isEmpty else {
      throw GeminiError.blocked(candidate["finishReason"] as? String ?? "empty")
    }
    guard let verdict = try? JSONDecoder().decode(CoachVerdict.self, from: Data(text.utf8)) else { throw GeminiError.badResponse }
    return verdict
  }

  static func errorMessage(_ data: Data) -> String {
    let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    return ((root?["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: data.prefix(200), as: UTF8.self)
  }

  // MARK: - Models

  /// Models this key can call with `method` ("generateContent" for the
  /// coach, "bidiGenerateContent" for Live), as ids ("gemini-…").
  public static func listModels(apiKey: String, method: String = "generateContent",
                                transport: HTTPTransport = URLSessionTransport()) async throws -> [String] {
    guard !apiKey.isEmpty else { throw GeminiError.noKey }
    guard let url = URL(string: "\(base)/models?pageSize=200") else { throw GeminiError.badResponse }
    var request = URLRequest(url: url, timeoutInterval: 15)
    request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
    let (data, status) = try await transport.send(request)
    guard (200..<300).contains(status) else { throw GeminiError.http(status, errorMessage(data)) }
    return parseModels(data, method: method)
  }

  static func parseModels(_ data: Data, method: String = "generateContent") -> [String] {
    let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let models = (root?["models"] as? [[String: Any]]) ?? []
    return models.compactMap { model in
      guard let name = model["name"] as? String,
            (model["supportedGenerationMethods"] as? [String] ?? []).contains(method)
      else { return nil }
      return name.hasPrefix("models/") ? String(name.dropFirst(7)) : name
    }
  }

  /// A good default coach: the newest stable "flash" model that is not a
  /// live, speech, image or embedding variant; "lite" and previews only if
  /// nothing else.
  public static func pickDefault(from models: [String]) -> String? {
    let excluded = ["live", "tts", "image", "audio", "embedding", "transcribe", "translate", "robotics", "computer"]
    let flash = models.filter { name in
      name.contains("flash") && !excluded.contains(where: name.contains)
    }
    func version(_ name: String) -> Double {
      let parts = name.split(separator: "-")
      return parts.compactMap { Double($0) }.first ?? 0
    }
    func rank(_ name: String) -> (Int, Double) {
      let unstable = name.contains("preview") || name.contains("exp")
      let lite = name.contains("lite")
      return ((unstable ? 2 : 0) + (lite ? 1 : 0), -version(name))
    }
    return flash.min { rank($0) < rank($1) }
  }
}
