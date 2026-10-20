import XCTest
@testable import GenioCore

final class GeminiCloseLookTests: XCTestCase {
  private func answer(_ json: String) -> String {
    let escaped = json.replacingOccurrences(of: "\"", with: "\\\"")
    return #"{"candidates": [{"content": {"parts": [{"text": ""# + escaped + #""}]}, "finishReason": "STOP"}]}"#
  }

  func testRequestAsksForHighResolution() throws {
    let request = try GeminiCloseLook.request(apiKey: "k", model: "models/gemini-3.5-flash", image: Data([0xFF, 0xD8]), prompt: "leggi")
    XCTAssertEqual(request.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent")
    XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "k")
    let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    let config = body["generationConfig"] as? [String: Any]
    XCTAssertEqual(config?["mediaResolution"] as? String, "MEDIA_RESOLUTION_HIGH")
    let schema = config?["responseSchema"] as? [String: Any]
    XCTAssertEqual((schema?["required"] as? [String])?.sorted(), ["answer", "confident", "retry_hint", "text_seen"])
    let parts = ((body["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]]) ?? []
    XCTAssertEqual((parts.first?["inlineData"] as? [String: Any])?["mimeType"] as? String, "image/jpeg")
  }

  func testPromptCarriesTheQuestionAndTheStep() {
    let prompt = GeminiCloseLook.prompt(question: "What model number is on the label?", goal: "Pulire il filtro",
                                        step: "Leggi il modello", language: "Italian")
    XCTAssertTrue(prompt.contains("What model number is on the label?"))
    XCTAssertTrue(prompt.contains("Pulire il filtro"))
    XCTAssertTrue(prompt.contains("\"Leggi il modello\""))
    XCTAssertTrue(prompt.contains("Italian"))
    XCTAssertFalse(GeminiCloseLook.prompt(question: "q", goal: nil, step: nil, language: "English").contains("Current step"))
  }

  func testLookParsesTheAnswer() async throws {
    let transport = MockTransport(json: answer(
      #"{"answer": "C'è scritto WAT28400IT.", "text_seen": "WAT28400IT", "confident": true, "retry_hint": ""}"#))
    let looker = GeminiCloseLook(apiKey: "k", model: "gemini-3.5-flash", languageName: "Italian", transport: transport)
    let found = try await looker.look(image: Data([1]), question: "model?", goal: nil, step: nil)
    XCTAssertEqual(found, CloseLookAnswer(answer: "C'è scritto WAT28400IT.", textSeen: "WAT28400IT", confident: true, retryHint: ""))
    XCTAssertEqual(transport.requests.count, 1)
  }

  func testMissingFieldsAreNotConfident() throws {
    let found = try GeminiCloseLook.parse(Data(answer(#"{"answer": "forse una M4"}"#).utf8))
    XCTAssertFalse(found.confident)
    XCTAssertEqual(found.textSeen, "")
  }

  func testErrors() async {
    let looker = GeminiCloseLook(apiKey: "k", model: "m", languageName: "Italian",
                                 transport: MockTransport(json: #"{"error": {"message": "quota"}}"#, status: 429))
    do {
      _ = try await looker.look(image: Data([1]), question: "q", goal: nil, step: nil)
      XCTFail("expected an error")
    } catch {
      XCTAssertEqual(error as? GeminiError, .http(429, "quota"))
    }
  }
}

@MainActor
final class LookCloselyToolTests: XCTestCase {
  private var engine: TaskEngine!
  private var tools: TaskTools!
  private var cameraOn = true
  private var asked: [String] = []

  override func setUp() async throws {
    engine = TaskEngine()
    tools = TaskTools(engine: engine)
    tools.cameraIsOn = { [unowned self] in self.cameraOn }
  }

  private func look(_ args: [String: Any], result: TaskTools.CloseLookResult) async -> JSONValue {
    tools.onCloseLook = { [unowned self] question in
      self.asked.append(question)
      return result
    }
    let call = FunctionCall(id: "1", name: TaskTools.Name.lookClosely.rawValue, args: JSONValue(any: args))
    XCTAssertTrue(TaskTools.isSlow(call))
    return await tools.handleSlow(call).response
  }

  func testDeclared() {
    let declaration = TaskTools.declarations.first { $0.name == "look_closely" }
    XCTAssertNotNil(declaration)
  }

  func testConfidentAnswer() async {
    let found = CloseLookAnswer(answer: "È una vite M4.", textSeen: "M4", confident: true, retryHint: "")
    let result = await look(["question": "Which screw?"], result: .answer(found, source: "photo"))
    XCTAssertEqual(result["status"], .string("accepted"))
    XCTAssertEqual(result["answer"], .string("È una vite M4."))
    XCTAssertEqual(result["text_seen"], .string("M4"))
    XCTAssertEqual(result["image"], .string("photo"))
    XCTAssertNil(result["retry_hint"])
    XCTAssertEqual(asked, ["Which screw?"])
  }

  func testUnsureAnswerAsksToShowItBetter() async {
    let found = CloseLookAnswer(answer: "Non si legge.", textSeen: "", confident: false, retryHint: "Avvicinati e fai più luce.")
    let result = await look(["question": "Model?"], result: .answer(found, source: "frame"))
    XCTAssertEqual(result["confident"], .bool(false))
    XCTAssertEqual(result["retry_hint"], .string("Avvicinati e fai più luce."))
    XCTAssertTrue(result["instruction"]?.stringValue?.contains("Do not guess") == true)
  }

  func testRefusals() async {
    var result = await look([:], result: .noImage)
    XCTAssertEqual(result["status"], .string("refused"))
    XCTAssertTrue(asked.isEmpty, "no look without a question")

    cameraOn = false
    result = await look(["question": "Model?"], result: .noImage)
    XCTAssertTrue(result["error"]?.stringValue?.contains("turn_on_camera") == true)
    XCTAssertTrue(asked.isEmpty, "no look with the camera off")

    cameraOn = true
    result = await look(["question": "Model?"], result: .noImage)
    XCTAssertEqual(result["status"], .string("refused"))
    result = await look(["question": "Model?"], result: .failed("timeout"))
    XCTAssertTrue(result["error"]?.stringValue?.contains("timeout") == true)
  }

  func testTheQuickPathDoesNotRunIt() {
    let call = FunctionCall(id: "1", name: TaskTools.Name.lookClosely.rawValue, args: JSONValue(any: ["question": "q"]))
    XCTAssertEqual(tools.handle(call).response["status"], .string("refused"))
    XCTAssertFalse(TaskTools.isSlow(FunctionCall(id: "2", name: "get_task_state", args: .null)))
  }
}

final class SharpnessTests: XCTestCase {
  func testEdgesScoreHigherThanBlur() {
    let width = 16, height = 16
    // A checkerboard of 2-pixel squares, and the same averaged out.
    let sharp = (0..<(width * height)).map { i -> UInt8 in ((i % width) / 2 + (i / width) / 2) % 2 == 0 ? 0 : 255 }
    let blurred = [UInt8](repeating: 128, count: width * height)
    XCTAssertGreaterThan(Sharpness.score(gray: sharp, width: width, height: height),
                         Sharpness.score(gray: blurred, width: width, height: height))
    XCTAssertEqual(Sharpness.score(gray: blurred, width: width, height: height), 0)
    XCTAssertEqual(Sharpness.score(gray: [1, 2], width: 2, height: 1), 0)
  }
}
