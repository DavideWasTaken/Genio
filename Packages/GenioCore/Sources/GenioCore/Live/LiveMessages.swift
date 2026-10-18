import Foundation

// The Gemini Live API wire format (BidiGenerateContent over WebSocket),
// as documented at https://ai.google.dev/api/live and
// https://ai.google.dev/gemini-api/docs/live-api. Every client message has
// exactly one top-level key: setup, clientContent, realtimeInput or
// toolResponse.

/// The endpoint for API-key sessions (v1beta).
public enum LiveEndpoint {
  public static let host = "generativelanguage.googleapis.com"
  public static let path = "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

  public static func url(apiKey: String) -> URL? {
    var components = URLComponents()
    components.scheme = "wss"
    components.host = host
    components.path = path
    components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
    return components.url
  }
}

/// An OpenAPI-style schema, as Gemini function declarations take it.
public indirect enum Schema: Sendable {
  case string(description: String, enumValues: [String]? = nil)
  case integer(description: String)
  case boolean(description: String)
  case array(description: String, items: Schema, minItems: Int? = nil, maxItems: Int? = nil)
  case object(properties: [(String, Schema)], required: [String])

  public var json: [String: Any] {
    switch self {
    case .string(let description, let enumValues):
      var value: [String: Any] = ["type": "STRING", "description": description]
      if let enumValues { value["enum"] = enumValues }
      return value
    case .integer(let description):
      return ["type": "INTEGER", "description": description]
    case .boolean(let description):
      return ["type": "BOOLEAN", "description": description]
    case .array(let description, let items, let minItems, let maxItems):
      var value: [String: Any] = ["type": "ARRAY", "description": description, "items": items.json]
      if let minItems { value["minItems"] = minItems }
      if let maxItems { value["maxItems"] = maxItems }
      return value
    case .object(let properties, let required):
      var props: [String: Any] = [:]
      for (name, schema) in properties { props[name] = schema.json }
      return ["type": "OBJECT", "properties": props, "required": required]
    }
  }
}

public struct FunctionDeclaration: Sendable {
  /// BLOCKING: the model waits for the result (state changes it must not
  /// announce before the engine accepts them). NON_BLOCKING: it carries on.
  public enum Behavior: String, Sendable {
    case blocking = "BLOCKING"
    case nonBlocking = "NON_BLOCKING"
  }

  public let name: String
  public let description: String
  public let parameters: Schema?
  public let behavior: Behavior

  public init(name: String, description: String, parameters: Schema?, behavior: Behavior) {
    self.name = name
    self.description = description
    self.parameters = parameters
    self.behavior = behavior
  }

  public var json: [String: Any] {
    var value: [String: Any] = ["name": name, "description": description, "behavior": behavior.rawValue]
    if let parameters { value["parameters"] = parameters.json }
    return value
  }
}

public struct FunctionCall: Equatable, Sendable {
  public let id: String
  public let name: String
  public let args: JSONValue

  public init(id: String, name: String, args: JSONValue) {
    self.id = id
    self.name = name
    self.args = args
  }
}

public struct FunctionResponse: Equatable, Sendable {
  /// How a NON_BLOCKING result reaches the conversation.
  public enum Scheduling: String, Sendable {
    case interrupt = "INTERRUPT"
    case whenIdle = "WHEN_IDLE"
    case silent = "SILENT"
  }

  public let id: String
  public let name: String
  public let response: JSONValue
  public let scheduling: Scheduling?

  public init(id: String, name: String, response: JSONValue, scheduling: Scheduling? = nil) {
    self.id = id
    self.name = name
    self.response = response
    self.scheduling = scheduling
  }

  var json: [String: Any] {
    var body = (response.any as? [String: Any]) ?? ["result": response.any]
    if let scheduling { body["scheduling"] = scheduling.rawValue }
    return ["id": id, "name": name, "response": body]
  }
}

/// How the server detects the user's turns.
public struct VoiceActivitySettings: Equatable, Sendable {
  /// LOW: harder to trigger, for noisy workshops and kitchens.
  public var startSensitivityLow = false
  public var endSensitivityLow = false
  public var silenceDurationMs = 700
  public var prefixPaddingMs = 200

  public init() {}
}

/// Everything sent in the first message of a connection.
public struct LiveSetup: Sendable {
  public var model: String
  public var voiceName: String?
  public var systemInstruction: String
  public var tools: [FunctionDeclaration]
  public var resumptionHandle: String?
  public var transcribe = true
  public var voiceActivity = VoiceActivitySettings()
  /// Lower tokens per frame: the coach needs shapes, not fine print.
  public var mediaResolution = "MEDIA_RESOLUTION_LOW"

  public init(model: String, voiceName: String?, systemInstruction: String, tools: [FunctionDeclaration], resumptionHandle: String?) {
    self.model = model
    self.voiceName = voiceName
    self.systemInstruction = systemInstruction
    self.tools = tools
    self.resumptionHandle = resumptionHandle
  }
}

public enum LiveClientMessage {
  public static func setup(_ s: LiveSetup) -> [String: Any] {
    var generation: [String: Any] = [
      "responseModalities": ["AUDIO"],
      "mediaResolution": s.mediaResolution,
    ]
    if let voice = s.voiceName, !voice.isEmpty {
      generation["speechConfig"] = ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voice]]]
    }
    var setup: [String: Any] = [
      "model": s.model.hasPrefix("models/") ? s.model : "models/\(s.model)",
      "generationConfig": generation,
      "systemInstruction": ["parts": [["text": s.systemInstruction]]],
      "realtimeInputConfig": [
        "automaticActivityDetection": [
          "disabled": false,
          "startOfSpeechSensitivity": s.voiceActivity.startSensitivityLow ? "START_SENSITIVITY_LOW" : "START_SENSITIVITY_HIGH",
          "endOfSpeechSensitivity": s.voiceActivity.endSensitivityLow ? "END_SENSITIVITY_LOW" : "END_SENSITIVITY_HIGH",
          "prefixPaddingMs": s.voiceActivity.prefixPaddingMs,
          "silenceDurationMs": s.voiceActivity.silenceDurationMs,
        ],
        // The user speaking interrupts Genio (barge-in).
        "activityHandling": "START_OF_ACTIVITY_INTERRUPTS",
      ],
      // Without compression an audio+video session ends after 2 minutes.
      "contextWindowCompression": ["slidingWindow": [String: Any]()],
      "sessionResumption": s.resumptionHandle.map { ["handle": $0] } ?? [String: Any](),
    ]
    if !s.tools.isEmpty {
      setup["tools"] = [["functionDeclarations": s.tools.map(\.json)]]
    }
    if s.transcribe {
      setup["inputAudioTranscription"] = [String: Any]()
      setup["outputAudioTranscription"] = [String: Any]()
    }
    return ["setup": setup]
  }

  /// 16-bit little-endian mono PCM at `rate` Hz.
  public static func audio(_ pcm: Data, rate: Int = 16_000) -> [String: Any] {
    ["realtimeInput": ["audio": ["data": pcm.base64EncodedString(), "mimeType": "audio/pcm;rate=\(rate)"]]]
  }

  public static func video(jpeg: Data) -> [String: Any] {
    ["realtimeInput": ["video": ["data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"]]]
  }

  public static func text(_ text: String) -> [String: Any] {
    ["realtimeInput": ["text": text]]
  }

  public static func audioStreamEnd() -> [String: Any] {
    ["realtimeInput": ["audioStreamEnd": true]]
  }

  /// Ordered text appended to the history; `turnComplete` makes the model
  /// answer it (and interrupts what it is saying).
  public static func clientText(_ text: String, turnComplete: Bool) -> [String: Any] {
    ["clientContent": ["turns": [["role": "user", "parts": [["text": text]]]], "turnComplete": turnComplete]]
  }

  public static func toolResponse(_ responses: [FunctionResponse]) -> [String: Any] {
    ["toolResponse": ["functionResponses": responses.map(\.json)]]
  }

  public static func encode(_ message: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8)
    else { return "{}" }
    return text
  }
}

public struct LiveUsage: Equatable, Sendable {
  public var promptTokens = 0
  public var responseTokens = 0
  public var totalTokens = 0

  public init(promptTokens: Int = 0, responseTokens: Int = 0, totalTokens: Int = 0) {
    self.promptTokens = promptTokens
    self.responseTokens = responseTokens
    self.totalTokens = totalTokens
  }
}

/// One thing a server message says. A message can say several (audio and
/// its transcript, turn complete and usage), in this order.
public enum LiveServerEvent: Equatable, Sendable {
  case setupComplete
  case audio(Data)
  case text(String)
  case inputTranscript(String)
  case outputTranscript(String)
  case interrupted
  case generationComplete
  case turnComplete
  case toolCall([FunctionCall])
  case toolCallCancellation([String])
  /// The server will close the connection in `timeLeft` seconds (nil if unreadable).
  case goAway(timeLeft: TimeInterval?)
  case resumptionUpdate(handle: String?, resumable: Bool)
  case usage(LiveUsage)
  /// An error object in the message, if the server sends one.
  case serverError(String)
}

public enum LiveServerMessage {
  /// Decodes one WebSocket message (text or binary frame, both carry JSON).
  public static func events(from data: Data) -> [LiveServerEvent] {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
    var events: [LiveServerEvent] = []
    if root["setupComplete"] != nil { events.append(.setupComplete) }

    if let content = root["serverContent"] as? [String: Any] {
      if let turn = content["modelTurn"] as? [String: Any], let parts = turn["parts"] as? [[String: Any]] {
        for part in parts {
          if let inline = part["inlineData"] as? [String: Any], let base64 = inline["data"] as? String,
             let audio = Data(base64Encoded: base64) {
            let mime = inline["mimeType"] as? String ?? "audio/pcm"
            if mime.hasPrefix("audio") { events.append(.audio(audio)) }
          } else if let text = part["text"] as? String, part["thought"] as? Bool != true {
            events.append(.text(text))
          }
        }
      }
      if let input = content["inputTranscription"] as? [String: Any], let text = input["text"] as? String, !text.isEmpty {
        events.append(.inputTranscript(text))
      }
      if let output = content["outputTranscription"] as? [String: Any], let text = output["text"] as? String, !text.isEmpty {
        events.append(.outputTranscript(text))
      }
      if content["interrupted"] as? Bool == true { events.append(.interrupted) }
      if content["generationComplete"] as? Bool == true { events.append(.generationComplete) }
      if content["turnComplete"] as? Bool == true { events.append(.turnComplete) }
    }

    if let toolCall = root["toolCall"] as? [String: Any], let calls = toolCall["functionCalls"] as? [[String: Any]] {
      let parsed = calls.compactMap { call -> FunctionCall? in
        guard let name = call["name"] as? String else { return nil }
        let id = call["id"] as? String ?? UUID().uuidString
        return FunctionCall(id: id, name: name, args: JSONValue(any: call["args"] ?? [String: Any]()))
      }
      if !parsed.isEmpty { events.append(.toolCall(parsed)) }
    }
    if let cancellation = root["toolCallCancellation"] as? [String: Any], let ids = cancellation["ids"] as? [String] {
      events.append(.toolCallCancellation(ids))
    }
    if let goAway = root["goAway"] as? [String: Any] {
      events.append(.goAway(timeLeft: duration(goAway["timeLeft"])))
    }
    if let update = root["sessionResumptionUpdate"] as? [String: Any] {
      let handle = (update["newHandle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      events.append(.resumptionUpdate(handle: handle, resumable: update["resumable"] as? Bool ?? (handle != nil)))
    }
    if let usage = root["usageMetadata"] as? [String: Any] {
      events.append(.usage(LiveUsage(
        promptTokens: usage["promptTokenCount"] as? Int ?? 0,
        responseTokens: usage["responseTokenCount"] as? Int ?? 0,
        totalTokens: usage["totalTokenCount"] as? Int ?? 0)))
    }
    if let error = root["error"] as? [String: Any] {
      events.append(.serverError(error["message"] as? String ?? "\(error)"))
    }
    return events
  }

  /// A protobuf Duration as JSON: "12.5s", or {"seconds": 12, "nanos": 0}.
  static func duration(_ value: Any?) -> TimeInterval? {
    if let text = value as? String {
      let trimmed = text.hasSuffix("s") ? String(text.dropLast()) : text
      return TimeInterval(trimmed)
    }
    if let object = value as? [String: Any] {
      let seconds = (object["seconds"] as? NSNumber)?.doubleValue ?? Double(object["seconds"] as? String ?? "") ?? 0
      let nanos = (object["nanos"] as? NSNumber)?.doubleValue ?? 0
      return seconds + nanos / 1e9
    }
    if let number = value as? NSNumber { return number.doubleValue }
    return nil
  }
}
