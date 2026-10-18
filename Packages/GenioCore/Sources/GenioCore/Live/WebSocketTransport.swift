import Foundation

public enum WebSocketMessage: Sendable {
  case text(String)
  case data(Data)

  public var payload: Data {
    switch self {
    case .text(let text): return Data(text.utf8)
    case .data(let data): return data
    }
  }
}

/// One WebSocket connection. Abstracted so the Live session can be tested
/// without a network.
public protocol WebSocketConnection: AnyObject, Sendable {
  func send(_ text: String) async throws
  /// The next message; throws when the connection closes or fails.
  func receive() async throws -> WebSocketMessage
  func close()
  /// How the server closed the connection, once it has (code, reason).
  var closeInfo: (code: Int, reason: String)? { get }
}

public protocol WebSocketConnector: Sendable {
  func connect(to url: URL) -> WebSocketConnection
}

/// URLSession's WebSocket, the production transport.
public final class URLSessionWebSocketConnector: WebSocketConnector {
  private let session: URLSession

  public init() {
    let configuration = URLSessionConfiguration.default
    configuration.waitsForConnectivity = false
    configuration.timeoutIntervalForRequest = 20
    session = URLSession(configuration: configuration)
  }

  public func connect(to url: URL) -> WebSocketConnection {
    let task = session.webSocketTask(with: url)
    // Audio replies are a few hundred KB at most; leave headroom.
    task.maximumMessageSize = 16 * 1024 * 1024
    task.resume()
    return URLSessionWebSocketConnection(task: task)
  }
}

final class URLSessionWebSocketConnection: WebSocketConnection, @unchecked Sendable {
  private let task: URLSessionWebSocketTask

  init(task: URLSessionWebSocketTask) {
    self.task = task
  }

  func send(_ text: String) async throws {
    try await task.send(.string(text))
  }

  func receive() async throws -> WebSocketMessage {
    switch try await task.receive() {
    case .string(let text): return .text(text)
    case .data(let data): return .data(data)
    @unknown default: return .data(Data())
    }
  }

  func close() {
    task.cancel(with: .normalClosure, reason: nil)
  }

  var closeInfo: (code: Int, reason: String)? {
    guard task.closeCode != .invalid else { return nil }
    let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    return (task.closeCode.rawValue, reason)
  }
}
