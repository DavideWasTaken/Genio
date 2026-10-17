import Foundation

/// Claude over the Messages API (raw HTTP: there is no official Swift SDK).
/// The coach runs on Claude Haiku 5.5; planning and questions on the model
/// chosen in Settings (Opus 5.5 by default).
///
/// Uses an API key from the Claude Console, billed per use: the Claude.ai
/// subscription cannot be used by your own app.
struct ClaudeBrain: Brain {
  var apiKey: String
  var coachModel = "claude-haiku-5-5"
  var smartModel = "claude-opus-5-5"

  func coach(image: Data, goal: String, steps: [String], current: Int, recentRemarks: [String]) async throws -> CoachVerdict {
    let text = try await send(
      model: coachModel,
      system: Prompts.coachInstructions,
      content: [imageBlock(image), textBlock(Prompts.coach(goal: goal, steps: steps, current: current, recentRemarks: recentRemarks))],
      maxTokens: 1024,
      schema: Prompts.coachSchema)
    return try Prompts.decode(CoachVerdict.self, from: text)
  }

  func plan(request: String, image: Data?) async throws -> Plan {
    var content: [[String: Any]] = []
    if let image { content.append(imageBlock(image)) }
    content.append(textBlock(Prompts.plan(request: request, hasImage: image != nil)))
    let text = try await send(
      model: smartModel, system: Prompts.planInstructions, content: content,
      maxTokens: 4096, schema: Prompts.planSchema)
    return try Prompts.decode(Plan.self, from: text)
  }

  func answer(question: String, image: Data?, taskContext: String?) async throws -> String {
    var content: [[String: Any]] = []
    if let image { content.append(imageBlock(image)) }
    content.append(textBlock(Prompts.answer(question: question, hasImage: image != nil, taskContext: taskContext)))
    return try await send(
      model: smartModel, system: Prompts.answerInstructions, content: content,
      maxTokens: 2048, schema: nil)
  }

  func followUp(message: String, image: Data?, goal: String, steps: [String], current: Int) async throws -> FollowUp {
    var content: [[String: Any]] = []
    if let image { content.append(imageBlock(image)) }
    content.append(textBlock(Prompts.followUp(
      message: message, hasImage: image != nil, goal: goal, steps: steps, current: current)))
    let text = try await send(
      model: smartModel, system: Prompts.followUpInstructions, content: content,
      maxTokens: 4096, schema: Prompts.followUpSchema)
    return try Prompts.decode(FollowUp.self, from: text)
  }

  // MARK: - HTTP

  private func imageBlock(_ jpeg: Data) -> [String: Any] {
    [
      "type": "image",
      "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()],
    ]
  }

  private func textBlock(_ text: String) -> [String: Any] {
    ["type": "text", "text": text]
  }

  private func send(
    model: String,
    system: String,
    content: [[String: Any]],
    maxTokens: Int,
    schema: [String: Any]?
  ) async throws -> String {
    guard !apiKey.isEmpty else { throw BrainError.noKey }

    // Low effort: spoken answers and quick visual checks, where speed matters
    // more than depth.
    var outputConfig: [String: Any] = ["effort": "low"]
    if let schema { outputConfig["format"] = ["type": "json_schema", "schema": schema] }
    var body: [String: Any] = [
      "model": model,
      "max_tokens": maxTokens,
      "system": system,
      "messages": [["role": "user", "content": content]],
      "output_config": outputConfig,
    ]

    var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 45
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    // Opus/Sonnet: if a safety classifier declines, the API retries on a
    // suitable model inside the same call. Haiku has no server-side fallback.
    if !model.hasPrefix("claude-haiku") {
      body["fallbacks"] = "default"
      request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200, let json else {
      let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "risposta vuota"
      throw BrainError.http("Claude", status, message)
    }
    if json["stop_reason"] as? String == "refusal" { throw BrainError.refused }
    // Content may also hold thinking (and fallback) blocks: keep the text only.
    let blocks = json["content"] as? [[String: Any]] ?? []
    let text = blocks
      .filter { $0["type"] as? String == "text" }
      .compactMap { $0["text"] as? String }
      .joined()
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw BrainError.badResponse }
    return text
  }
}
