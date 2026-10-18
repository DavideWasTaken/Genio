import XCTest
@testable import GenioCore

final class MockTransport: HTTPTransport, @unchecked Sendable {
  let lock = NSLock()
  var requests: [URLRequest] = []
  let reply: (Data, Int)

  init(json: String, status: Int = 200) {
    reply = (Data(json.utf8), status)
  }

  func send(_ request: URLRequest) async throws -> (Data, Int) {
    lock.withLock { requests.append(request) }
    return reply
  }
}

final class GeminiVisionCoachTests: XCTestCase {
  private func answer(_ verdictJSON: String) -> String {
    let escaped = verdictJSON.replacingOccurrences(of: "\"", with: "\\\"")
    return #"{"candidates": [{"content": {"parts": [{"text": ""# + escaped + #""}]}, "finishReason": "STOP"}]}"#
  }

  func testRequestFormat() throws {
    let request = try GeminiVisionCoach.request(apiKey: "k", model: "models/gemini-3.5-flash", image: Data([0xFF, 0xD8]), prompt: "guarda")
    XCTAssertEqual(request.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent")
    XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "k")
    XCTAssertNil(request.url?.query, "the key is not in the URL")
    let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    let parts = ((body["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]]) ?? []
    XCTAssertEqual((parts.first?["inlineData"] as? [String: Any])?["mimeType"] as? String, "image/jpeg")
    XCTAssertEqual(parts.last?["text"] as? String, "guarda")
    let config = body["generationConfig"] as? [String: Any]
    XCTAssertEqual(config?["responseMimeType"] as? String, "application/json")
    let schema = config?["responseSchema"] as? [String: Any]
    XCTAssertEqual((schema?["required"] as? [String])?.sorted(), ["evidence", "kind", "say", "verdict"])
  }

  func testCoachParsesTheVerdict() async throws {
    let transport = MockTransport(json: answer(#"{"verdict": "completed", "evidence": "il filtro è fuori", "say": "", "kind": "info"}"#))
    let coach = GeminiVisionCoach(apiKey: "k", model: "gemini-3.5-flash", languageName: "Italian", transport: transport)
    let verdict = try await coach.coach(image: Data([1]), goal: "Filtro", steps: ["a", "b"], current: 1, recentRemarks: [])
    XCTAssertEqual(verdict, CoachVerdict(verdict: .completed, evidence: "il filtro è fuori", say: "", kind: .info))
    XCTAssertEqual(transport.requests.count, 1)
  }

  func testUnknownValuesFallBackToTheCautiousOnes() throws {
    let verdict = try GeminiVisionCoach.parse(Data(answer(#"{"verdict": "maybe", "evidence": "", "say": "", "kind": "?"}"#).utf8))
    XCTAssertEqual(verdict.verdict, .uncertain)
    XCTAssertEqual(verdict.kind, .info)
  }

  func testErrors() async {
    let coach = GeminiVisionCoach(apiKey: "k", model: "m", languageName: "Italian",
                                  transport: MockTransport(json: #"{"error": {"message": "API key not valid"}}"#, status: 400))
    do {
      _ = try await coach.coach(image: Data([1]), goal: "g", steps: ["a"], current: 0, recentRemarks: [])
      XCTFail("expected an error")
    } catch {
      XCTAssertEqual(error as? GeminiError, .http(400, "API key not valid"))
    }
    XCTAssertThrowsError(try GeminiVisionCoach.parse(Data(#"{"promptFeedback": {"blockReason": "SAFETY"}}"#.utf8))) {
      XCTAssertEqual($0 as? GeminiError, .blocked("SAFETY"))
    }
    let noKey = GeminiVisionCoach(apiKey: "", model: "m", languageName: "Italian", transport: MockTransport(json: "{}"))
    do {
      _ = try await noKey.coach(image: Data([1]), goal: "g", steps: ["a"], current: 0, recentRemarks: [])
      XCTFail("expected noKey")
    } catch {
      XCTAssertEqual(error as? GeminiError, .noKey)
    }
  }

  func testModelListAndDefault() async throws {
    let list = """
      {"models": [
        {"name": "models/gemini-3.8-live", "supportedGenerationMethods": ["bidiGenerateContent"]},
        {"name": "models/gemini-3.5-flash", "supportedGenerationMethods": ["generateContent", "countTokens"]},
        {"name": "models/gemini-3.5-flash-lite", "supportedGenerationMethods": ["generateContent"]},
        {"name": "models/gemini-3.9-flash-preview", "supportedGenerationMethods": ["generateContent"]},
        {"name": "models/gemini-3.5-flash-image", "supportedGenerationMethods": ["generateContent"]},
        {"name": "models/gemini-2.5-flash", "supportedGenerationMethods": ["generateContent"]},
        {"name": "models/text-embedding-004", "supportedGenerationMethods": ["embedContent"]}
      ]}
      """
    let models = try await GeminiVisionCoach.listModels(apiKey: "k", transport: MockTransport(json: list))
    XCTAssertEqual(models.count, 5)
    XCTAssertFalse(models.contains("gemini-3.8-live"))
    XCTAssertEqual(GeminiVisionCoach.pickDefault(from: models), "gemini-3.5-flash")
    XCTAssertEqual(GeminiVisionCoach.pickDefault(from: ["gemini-3.5-flash-lite", "gemini-3.9-flash-preview"]), "gemini-3.5-flash-lite")
    XCTAssertNil(GeminiVisionCoach.pickDefault(from: ["gemini-3.8-live"]))
    let live = try await GeminiVisionCoach.listModels(apiKey: "k", method: "bidiGenerateContent", transport: MockTransport(json: list))
    XCTAssertEqual(live, ["gemini-3.8-live"])
  }
}
