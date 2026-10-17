import Foundation

/// ChatGPT through "Sign in with ChatGPT" plan usage: the Responses API with
/// your ChatGPT plan's token. Plan usage requires `store: false` and
/// `stream: true` on every request, the whole input in `input`, and
/// `instructions` instead of system messages; audio is not supported (the
/// voice stays on the glasses and the iPhone).
///
/// Docs: https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference
struct ChatGPTBrain: Brain {
  var coachModel: String
  var smartModel: String
  var auth: ChatGPTAuth = .shared

  struct Model: Identifiable, Hashable {
    let slug: String
    let name: String
    var id: String { slug }
  }

  /// Models this account may use, for the Settings pickers.
  static func models(auth: ChatGPTAuth = .shared) async throws -> [Model] {
    let token = try await auth.accessToken()
    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw BrainError.http("ChatGPT", status, Self.errorMessage(data))
    }
    // Plan usage lists `models[]` with slug / display_name / visibility;
    // fall back to the standard `data[]` list shape.
    if let entries = json["models"] as? [[String: Any]] {
      return entries.compactMap { entry in
        guard (entry["visibility"] as? String ?? "list") == "list",
              let slug = entry["slug"] as? String else { return nil }
        return Model(slug: slug, name: entry["display_name"] as? String ?? slug)
      }
    }
    let entries = json["data"] as? [[String: Any]] ?? []
    return entries.compactMap { ($0["id"] as? String).map { Model(slug: $0, name: $0) } }
  }

  func coach(image: Data, goal: String, steps: [String], current: Int, recentRemarks: [String]) async throws -> CoachVerdict {
    let text = try await send(
      model: coachModel,
      instructions: Prompts.coachInstructions,
      content: [imagePart(image), textPart(Prompts.coach(goal: goal, steps: steps, current: current, recentRemarks: recentRemarks))],
      schema: ("coach", Prompts.coachSchema))
    return try Prompts.decode(CoachVerdict.self, from: text)
  }

  func plan(request: String, image: Data?) async throws -> Plan {
    var content: [[String: Any]] = []
    if let image { content.append(imagePart(image)) }
    content.append(textPart(Prompts.plan(request: request, hasImage: image != nil)))
    let text = try await send(
      model: smartModel, instructions: Prompts.planInstructions, content: content,
      schema: ("plan", Prompts.planSchema))
    return try Prompts.decode(Plan.self, from: text)
  }

  func answer(question: String, image: Data?, taskContext: String?) async throws -> String {
    var content: [[String: Any]] = []
    if let image { content.append(imagePart(image)) }
    content.append(textPart(Prompts.answer(question: question, hasImage: image != nil, taskContext: taskContext)))
    return try await send(model: smartModel, instructions: Prompts.answerInstructions, content: content, schema: nil)
  }

  func followUp(message: String, image: Data?, goal: String, steps: [String], current: Int) async throws -> FollowUp {
    var content: [[String: Any]] = []
    if let image { content.append(imagePart(image)) }
    content.append(textPart(Prompts.followUp(
      message: message, hasImage: image != nil, goal: goal, steps: steps, current: current)))
    let text = try await send(
      model: smartModel, instructions: Prompts.followUpInstructions, content: content,
      schema: ("follow_up", Prompts.followUpSchema))
    return try Prompts.decode(FollowUp.self, from: text)
  }

  // MARK: - HTTP

  private func imagePart(_ jpeg: Data) -> [String: Any] {
    ["type": "input_image", "image_url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]
  }

  private func textPart(_ text: String) -> [String: Any] {
    ["type": "input_text", "text": text]
  }

  private func send(
    model: String,
    instructions: String,
    content: [[String: Any]],
    schema: (name: String, schema: [String: Any])?
  ) async throws -> String {
    // No model picked in Settings yet: use the first one the plan offers.
    var chosen = model
    if chosen.isEmpty {
      guard let first = try await Self.models(auth: auth).first?.slug else { throw BrainError.badResponse }
      chosen = first
    }
    let token = try await auth.accessToken()
    var body: [String: Any] = [
      "model": chosen,
      "instructions": instructions,
      "input": [["role": "user", "content": content]],
      "store": false,
      "stream": true,
    ]
    if let schema {
      body["text"] = [
        "format": ["type": "json_schema", "name": schema.name, "schema": schema.schema, "strict": true]
      ]
    }

    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 45
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else {
      var data = Data()
      for try await byte in bytes {
        data.append(byte)
        if data.count > 8192 { break }
      }
      if Self.errorCode(data) == "subscription_sharing_usage_limit_exceeded" { throw BrainError.usageLimit }
      throw BrainError.http("ChatGPT", status, Self.errorMessage(data))
    }

    // Server-sent events: collect the text deltas; only response.completed
    // counts as success.
    var text = ""
    for try await line in bytes.lines {
      guard line.hasPrefix("data:") else { continue }
      let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
      guard let data = payload.data(using: .utf8),
            let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { continue }
      switch event["type"] as? String {
      case "response.output_text.delta":
        text += event["delta"] as? String ?? ""
      case "response.completed":
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw BrainError.badResponse }
        return result
      case "response.failed", "error":
        let error = ((event["response"] as? [String: Any])?["error"] as? [String: Any]) ?? (event["error"] as? [String: Any]) ?? event
        let code = error["code"] as? String ?? ""
        if code == "subscription_sharing_usage_limit_exceeded" { throw BrainError.usageLimit }
        if code.hasPrefix("subscription_sharing_usage_unavailable") || code == "subscription_sharing_user_unavailable" {
          throw BrainError.http("ChatGPT", 503, code)
        }
        throw BrainError.http("ChatGPT", 0, error["message"] as? String ?? code)
      case "response.incomplete":
        throw BrainError.badResponse
      default:
        continue
      }
    }
    // The stream ended without response.completed: treat it as a failure.
    throw BrainError.badResponse
  }

  private static func errorCode(_ data: Data) -> String? {
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    return (json?["error"] as? [String: Any])?["code"] as? String
  }

  /// Errors before streaming may be `{"detail": "..."}` instead of the
  /// standard error object.
  private static func errorMessage(_ data: Data) -> String {
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    if let error = json?["error"] as? [String: Any] {
      return (error["message"] as? String) ?? (error["code"] as? String) ?? "error"
    }
    return (json?["detail"] as? String) ?? String(data: data.prefix(200), encoding: .utf8) ?? "error"
  }
}
