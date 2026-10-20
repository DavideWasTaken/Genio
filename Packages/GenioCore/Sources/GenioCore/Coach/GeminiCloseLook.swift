import Foundation

/// What a close look found.
public struct CloseLookAnswer: Equatable, Sendable, Decodable {
  /// The answer to the question, one or two spoken sentences.
  public let answer: String
  /// Text, numbers or markings read in the image, exactly as written ("" if none).
  public let textSeen: String
  /// The image clearly shows what was asked.
  public let confident: Bool
  /// How to show it better when not confident (closer, more light, another side).
  public let retryHint: String

  public init(answer: String, textSeen: String, confident: Bool, retryHint: String) {
    self.answer = answer
    self.textSeen = textSeen
    self.confident = confident
    self.retryHint = retryHint
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    answer = try container.decodeIfPresent(String.self, forKey: .answer) ?? ""
    textSeen = try container.decodeIfPresent(String.self, forKey: .textSeen) ?? ""
    confident = try container.decodeIfPresent(Bool.self, forKey: .confident) ?? false
    retryHint = try container.decodeIfPresent(String.self, forKey: .retryHint) ?? ""
  }

  enum CodingKeys: String, CodingKey {
    case answer
    case textSeen = "text_seen"
    case confident
    case retryHint = "retry_hint"
  }
}

/// One careful look at a sharp, high-resolution still (a photo from the
/// glasses, or the sharpest recent frame) to answer a precise question: the
/// text on a label, a model number, which screw, whether a part is seated.
/// Gemini Live sees the stream at about one small frame a second, which is
/// enough to follow a task but not to read small print; this goes to a vision
/// model through generateContent (REST) at high media resolution.
public struct GeminiCloseLook: Sendable {
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

  /// `step`: the current step's text, if a task is in progress.
  public func look(image: Data, question: String, goal: String?, step: String?) async throws -> CloseLookAnswer {
    guard !apiKey.isEmpty else { throw GeminiError.noKey }
    let request = try Self.request(
      apiKey: apiKey, model: model, image: image,
      prompt: Self.prompt(question: question, goal: goal, step: step, language: languageName))
    let (data, status) = try await transport.send(request)
    guard (200..<300).contains(status) else { throw GeminiError.http(status, GeminiVisionCoach.errorMessage(data)) }
    return try Self.parse(data)
  }

  // MARK: - Wire format (testable)

  public static let instructions =
    "You look closely at one still photo from smart glasses to answer a precise question during a hands-on task. You never guess."

  public static func prompt(question: String, goal: String?, step: String?, language: String) -> String {
    var context = ""
    if let goal, !goal.isEmpty { context += "The user is working on: \(goal).\n" }
    if let step, !step.isEmpty { context += "Current step: \"\(step)\".\n" }
    return """
      \(context)Question: \(question)

      Look at the photo carefully and answer:
      - answer: one or two short spoken sentences in \(language) that answer the question from what the photo shows.
        Quote numbers, sizes and printed text exactly. Say which part you mean by where it is ("the one on the left").
      - text_seen: any text, numbers or markings relevant to the question, exactly as written; "" if none.
      - confident: true only if the photo clearly shows what was asked (in focus, close enough, lit, not covered).
        If you would have to guess, false: a wrong reading is worse than none.
      - retry_hint: when not confident, how the user can show it better, in \(language) (closer, more light,
        turn it, hold still); "" otherwise.
      """
  }

  static var responseSchema: [String: Any] {
    Schema.object(properties: [
      ("answer", .string(description: "The answer, spoken, one or two short sentences.")),
      ("text_seen", .string(description: "Relevant text, numbers or markings exactly as written, or empty.")),
      ("confident", .boolean(description: "The photo clearly shows what was asked.")),
      ("retry_hint", .string(description: "How to show it better when not confident, or empty.")),
    ], required: ["answer", "text_seen", "confident", "retry_hint"]).json
  }

  public static func request(apiKey: String, model: String, image: Data, prompt: String) throws -> URLRequest {
    let name = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
    guard let url = URL(string: "\(GeminiVisionCoach.base)/models/\(name):generateContent") else { throw GeminiError.badResponse }
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
        "temperature": 0.1,
        // Small print needs every pixel the model can take.
        "mediaResolution": "MEDIA_RESOLUTION_HIGH",
      ],
    ]
    var request = URLRequest(url: url, timeoutInterval: 20)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return request
  }

  public static func parse(_ data: Data) throws -> CloseLookAnswer {
    let text = try GeminiVisionCoach.answerText(data)
    guard let answer = try? JSONDecoder().decode(CloseLookAnswer.self, from: Data(text.utf8)) else { throw GeminiError.badResponse }
    return answer
  }
}
