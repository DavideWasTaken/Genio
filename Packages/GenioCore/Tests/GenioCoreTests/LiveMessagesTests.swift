import XCTest
@testable import GenioCore

final class LiveMessagesTests: XCTestCase {
  private func json(_ message: [String: Any]) throws -> [String: Any] {
    let data = Data(LiveClientMessage.encode(message).utf8)
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  func testEndpointCarriesTheKeyAsAQueryParameter() throws {
    let url = try XCTUnwrap(LiveEndpoint.url(apiKey: "abc/123"))
    XCTAssertEqual(url.scheme, "wss")
    XCTAssertEqual(url.host, "generativelanguage.googleapis.com")
    XCTAssertTrue(url.path.hasSuffix("GenerativeService.BidiGenerateContent"))
    XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "abc/123")
  }

  func testSetupMessage() throws {
    var setup = LiveSetup(model: "gemini-3.8-live", voiceName: "Kore", systemInstruction: "Sei Genio.",
                          tools: TaskTools.declarations, resumptionHandle: "handle-1")
    setup.voiceActivity.startSensitivityLow = true
    let root = try json(LiveClientMessage.setup(setup))
    XCTAssertEqual(root.count, 1, "exactly one top-level key")
    let body = try XCTUnwrap(root["setup"] as? [String: Any])
    XCTAssertEqual(body["model"] as? String, "models/gemini-3.8-live")
    let generation = try XCTUnwrap(body["generationConfig"] as? [String: Any])
    XCTAssertEqual(generation["responseModalities"] as? [String], ["AUDIO"])
    let voice = ((generation["speechConfig"] as? [String: Any])?["voiceConfig"] as? [String: Any])?["prebuiltVoiceConfig"] as? [String: Any]
    XCTAssertEqual(voice?["voiceName"] as? String, "Kore")
    XCTAssertEqual(((body["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"] as? String, "Sei Genio.")
    XCTAssertEqual((body["sessionResumption"] as? [String: Any])?["handle"] as? String, "handle-1")
    XCTAssertNotNil((body["contextWindowCompression"] as? [String: Any])?["slidingWindow"])
    XCTAssertNotNil(body["inputAudioTranscription"])
    XCTAssertNotNil(body["outputAudioTranscription"])
    let detection = ((body["realtimeInputConfig"] as? [String: Any])?["automaticActivityDetection"] as? [String: Any])
    XCTAssertEqual(detection?["startOfSpeechSensitivity"] as? String, "START_SENSITIVITY_LOW")
    let tools = body["tools"] as? [[String: Any]] ?? []
    let declarations = (tools.first?["functionDeclarations"] as? [[String: Any]]) ?? []
    XCTAssertEqual(declarations.count, TaskTools.Name.allCases.count)
    XCTAssertTrue(tools.contains { $0["googleSearch"] != nil }, "Google Search grounding is on")
  }

  func testFreshSessionSendsAnEmptyResumptionObject() throws {
    let setup = LiveSetup(model: "models/gemini-3.8-live", voiceName: nil, systemInstruction: "x", tools: [], resumptionHandle: nil)
    let body = try XCTUnwrap(try json(LiveClientMessage.setup(setup))["setup"] as? [String: Any])
    XCTAssertEqual(body["model"] as? String, "models/gemini-3.8-live")
    XCTAssertEqual((body["sessionResumption"] as? [String: Any])?.isEmpty, true)
    XCTAssertEqual((body["tools"] as? [[String: Any]])?.count, 1, "only Google Search")
    XCTAssertNil((body["generationConfig"] as? [String: Any])?["speechConfig"])
  }

  func testRealtimeInputMessages() throws {
    let audio = try json(LiveClientMessage.audio(Data([1, 2, 3, 4])))
    let blob = (audio["realtimeInput"] as? [String: Any])?["audio"] as? [String: Any]
    XCTAssertEqual(blob?["mimeType"] as? String, "audio/pcm;rate=16000")
    XCTAssertEqual(blob?["data"] as? String, Data([1, 2, 3, 4]).base64EncodedString())
    let video = try json(LiveClientMessage.video(jpeg: Data([0xFF, 0xD8])))
    XCTAssertEqual(((video["realtimeInput"] as? [String: Any])?["video"] as? [String: Any])?["mimeType"] as? String, "image/jpeg")
    let response = try json(LiveClientMessage.toolResponse([
      FunctionResponse(id: "c1", name: "get_task_state", response: .object(["status": .string("ok")]), scheduling: .silent)
    ]))
    let first = ((response["toolResponse"] as? [String: Any])?["functionResponses"] as? [[String: Any]])?.first
    XCTAssertEqual(first?["id"] as? String, "c1")
    XCTAssertEqual((first?["response"] as? [String: Any])?["scheduling"] as? String, "SILENT")
    XCTAssertEqual((first?["response"] as? [String: Any])?["status"] as? String, "ok")
  }

  func testServerContentWithAudioAndTranscripts() {
    let audio = Data([0, 1, 2, 3]).base64EncodedString()
    let message = """
      {"serverContent": {"modelTurn": {"parts": [{"inlineData": {"mimeType": "audio/pcm;rate=24000", "data": "\(audio)"}}]},
       "outputTranscription": {"text": "Ciao"}, "inputTranscription": {"text": "fatto"}, "turnComplete": true},
       "usageMetadata": {"promptTokenCount": 10, "responseTokenCount": 5, "totalTokenCount": 15}}
      """
    let events = LiveServerMessage.events(from: Data(message.utf8))
    XCTAssertEqual(events, [
      .audio(Data([0, 1, 2, 3])), .inputTranscript("fatto"), .outputTranscript("Ciao"), .turnComplete,
      .usage(LiveUsage(promptTokens: 10, responseTokens: 5, totalTokens: 15)),
    ])
  }

  func testInterruptionToolCallsAndSessionMessages() {
    XCTAssertEqual(LiveServerMessage.events(from: Data(#"{"setupComplete": {}}"#.utf8)), [.setupComplete])
    XCTAssertEqual(LiveServerMessage.events(from: Data(#"{"serverContent": {"interrupted": true}}"#.utf8)), [.interrupted])
    let call = LiveServerMessage.events(from: Data(#"{"toolCall": {"functionCalls": [{"id": "a1", "name": "get_task_state", "args": {"n": 2}}]}}"#.utf8))
    XCTAssertEqual(call, [.toolCall([FunctionCall(id: "a1", name: "get_task_state", args: .object(["n": .number(2)]))])])
    XCTAssertEqual(LiveServerMessage.events(from: Data(#"{"toolCallCancellation": {"ids": ["a1"]}}"#.utf8)), [.toolCallCancellation(["a1"])])
    XCTAssertEqual(LiveServerMessage.events(from: Data(#"{"goAway": {"timeLeft": "12.5s"}}"#.utf8)), [.goAway(timeLeft: 12.5)])
    XCTAssertEqual(LiveServerMessage.events(from: Data(#"{"goAway": {"timeLeft": {"seconds": 8}}}"#.utf8)), [.goAway(timeLeft: 8)])
    XCTAssertEqual(LiveServerMessage.events(from: Data(#"{"sessionResumptionUpdate": {"newHandle": "h2", "resumable": true}}"#.utf8)),
                   [.resumptionUpdate(handle: "h2", resumable: true)])
    XCTAssertEqual(LiveServerMessage.events(from: Data(#"{"sessionResumptionUpdate": {"newHandle": "", "resumable": false}}"#.utf8)),
                   [.resumptionUpdate(handle: nil, resumable: false)])
    XCTAssertEqual(LiveServerMessage.events(from: Data("not json".utf8)), [])
  }

  func testThoughtsAreNotSpoken() {
    let message = #"{"serverContent": {"modelTurn": {"parts": [{"text": "thinking...", "thought": true}, {"text": "Ecco"}]}}}"#
    XCTAssertEqual(LiveServerMessage.events(from: Data(message.utf8)), [.text("Ecco")])
  }
}
