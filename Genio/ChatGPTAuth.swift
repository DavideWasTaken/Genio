import AuthenticationServices
import CryptoKit
import Foundation
import Network
import UIKit

/// "Sign in with ChatGPT" (plan usage for open-source and locally hosted
/// apps), so Genio's requests count against your ChatGPT Plus/Pro plan
/// instead of API credit.
///
/// OpenAI's flow: OAuth 2 with PKCE and dynamic registration (the first
/// sign-in uses `dynamic_agent_client` and the callback hands back this
/// app's own `client_id`), redirecting ONLY to an HTTP loopback address,
/// `http://127.0.0.1:<port>/auth/callback`. iOS is not mentioned in OpenAI's
/// docs, so the loopback is served from inside the app: a tiny listener on
/// 127.0.0.1 receives the redirect while the sign-in sheet is open.
///
/// Docs: https://developers.openai.com/siwc/token-sharing-open-source/sign-in
actor ChatGPTAuth {
  static let shared = ChatGPTAuth()

  struct Account: Codable {
    var clientId: String
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var email: String?
  }

  enum AuthError: LocalizedError {
    case cancelled
    case denied
    case stateMismatch
    case missingScope
    case invalidIDToken
    case listener(String)
    case server(String)

    var errorDescription: String? {
      switch self {
      case .cancelled: return String(localized: "Sign-in cancelled.")
      case .denied: return String(localized: "Access denied on ChatGPT.")
      case .stateMismatch: return String(localized: "Invalid sign-in response (state).")
      case .missingScope: return String(localized: "Your ChatGPT plan does not allow use from this app.")
      case .invalidIDToken: return String(localized: "Invalid identity token.")
      case .listener(let why): return String(localized: "Local sign-in server: \(why)")
      case .server(let why): return String(localized: "ChatGPT sign-in error: \(why)")
      }
    }
  }

  static let authorizeURL = URL(string: "https://auth.openai.com/api/accounts/authorize")!
  static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
  static let discoveryURL = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
  static let resource = "https://api.openai.com/v1"
  static let scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
  private static let requiredScope = "chatgpt.tokens.use.direct"
  private static let callbackPath = "/auth/callback"
  private static let ports: [UInt16] = [1455, 1456, 1457, 1458]

  private static let accountKey = "chatgpt.account"
  /// The issued client_id outlives a sign-out: later sign-ins reuse it
  /// instead of registering again.
  private static let clientIdKey = "chatgpt.clientId"
  private static let hostIdKey = "chatgpt.hostId"

  private var account: Account? = ChatGPTAuth.loadAccount()
  private var refreshing: Task<Account, Error>?

  var isSignedIn: Bool { account != nil }
  var email: String? { account?.email }

  /// A random per-device id, required by OpenAI to tell hosts apart. It
  /// carries nothing about the user, as the docs require.
  private static var hostId: String {
    if let saved = UserDefaults.standard.string(forKey: hostIdKey) { return saved }
    let fresh = "urn:uuid:\(UUID().uuidString.lowercased())"
    UserDefaults.standard.set(fresh, forKey: hostIdKey)
    return fresh
  }

  // MARK: - Sign in

  func signIn() async throws {
    let verifier = Self.randomURLSafe(32)
    let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
    let state = Self.randomURLSafe(16)
    let nonce = Self.randomURLSafe(16)
    let savedClientId = Keychain.string(Self.clientIdKey)

    let listener = try await LoopbackListener.start(ports: Self.ports, path: Self.callbackPath)
    defer { listener.stop() }
    let redirectURI = "http://127.0.0.1:\(listener.port)\(Self.callbackPath)"

    var items = [
      URLQueryItem(name: "client_id", value: savedClientId ?? "dynamic_agent_client"),
      URLQueryItem(name: "ext_agent_host_id", value: Self.hostId),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "redirect_uri", value: redirectURI),
      URLQueryItem(name: "scope", value: Self.scope),
      URLQueryItem(name: "resource", value: Self.resource),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "nonce", value: nonce),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "code_challenge", value: challenge),
    ]
    if savedClientId == nil {
      items.append(URLQueryItem(name: "agent_name_hint", value: "Genio"))
    }
    var components = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)!
    components.queryItems = items
    // URLComponents leaves "+" and ":" unescaped; OpenAI asks for every value
    // to be URL-encoded.
    components.percentEncodedQuery = components.percentEncodedQuery?
      .replacingOccurrences(of: "+", with: "%2B")
      .replacingOccurrences(of: ":", with: "%3A")

    let callback = try await WebSignIn.run(url: components.url!, until: listener.callback)

    if callback["error"] == "access_denied" { throw AuthError.denied }
    if let error = callback["error"] { throw AuthError.server(error) }
    guard callback["state"] == state else { throw AuthError.stateMismatch }
    guard let code = callback["code"] else { throw AuthError.server("no code") }
    guard let clientId = callback["client_id"] ?? savedClientId else {
      throw AuthError.server("no client_id")
    }
    Keychain.set(Data(clientId.utf8), for: Self.clientIdKey)

    let tokens = try await Self.tokenRequest([
      "grant_type": "authorization_code",
      "client_id": clientId,
      "code": code,
      "code_verifier": verifier,
      "redirect_uri": redirectURI,
      "resource": Self.resource,
    ])
    let email = try Self.checkIDToken(tokens["id_token"] as? String, clientId: clientId, nonce: nonce)
    let newAccount = try Self.account(from: tokens, clientId: clientId, email: email, previousRefresh: nil)
    save(newAccount)
  }

  // MARK: - Tokens

  /// A valid access token, refreshed when it is about to expire. Refreshes
  /// are serialized: refresh tokens rotate and a reused one is rejected.
  func accessToken() async throws -> String {
    guard let current = account else { throw BrainError.notSignedIn }
    if current.expiresAt.timeIntervalSinceNow > 120 { return current.accessToken }
    if let refreshing { return try await refreshing.value.accessToken }
    let task = Task { try await Self.refresh(current) }
    refreshing = task
    defer { refreshing = nil }
    do {
      let renewed = try await task.value
      save(renewed)
      return renewed.accessToken
    } catch BrainError.notSignedIn {
      save(nil)
      throw BrainError.notSignedIn
    }
  }

  private static func refresh(_ current: Account) async throws -> Account {
    do {
      let tokens = try await tokenRequest([
        "grant_type": "refresh_token",
        "client_id": current.clientId,
        "refresh_token": current.refreshToken,
        "resource": resource,
      ])
      return try account(from: tokens, clientId: current.clientId, email: current.email, previousRefresh: current.refreshToken)
    } catch AuthError.server(let code) where refreshFailures.contains(code) {
      // The grant is gone: the user must sign in again.
      throw BrainError.notSignedIn
    }
  }

  private static let refreshFailures: Set<String> = [
    "invalid_grant", "invalid_refresh_token", "token_expired",
    "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused",
  ]

  func signOut() async {
    guard let current = account else { return }
    save(nil)
    // Best effort: revoke the refresh token so it cannot be used again.
    if let discovery = try? await URLSession.shared.data(from: Self.discoveryURL).0,
       let json = try? JSONSerialization.jsonObject(with: discovery) as? [String: Any],
       let endpoint = (json["revocation_endpoint"] as? String).flatMap(URL.init(string:)) {
      var request = URLRequest(url: endpoint)
      request.httpMethod = "POST"
      request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
      request.httpBody = Self.formBody([
        "token": current.refreshToken,
        "token_type_hint": "refresh_token",
        "client_id": current.clientId,
      ])
      _ = try? await URLSession.shared.data(for: request)
    }
  }

  private func save(_ newAccount: Account?) {
    account = newAccount
    Keychain.set(newAccount.flatMap { try? JSONEncoder().encode($0) }, for: Self.accountKey)
  }

  private static func loadAccount() -> Account? {
    Keychain.data(accountKey).flatMap { try? JSONDecoder().decode(Account.self, from: $0) }
  }

  // MARK: - Helpers

  private static func account(from tokens: [String: Any], clientId: String, email: String?, previousRefresh: String?) throws -> Account {
    guard let access = tokens["access_token"] as? String else { throw AuthError.server("no access_token") }
    if let granted = tokens["scope"] as? String, !granted.split(separator: " ").contains(Substring(requiredScope)) {
      throw AuthError.missingScope
    }
    guard let refresh = (tokens["refresh_token"] as? String) ?? previousRefresh else {
      throw AuthError.server("no refresh_token")
    }
    let lifetime = (tokens["expires_in"] as? Double) ?? 3600
    return Account(
      clientId: clientId, accessToken: access, refreshToken: refresh,
      expiresAt: Date().addingTimeInterval(lifetime), email: email)
  }

  private static func tokenRequest(_ fields: [String: String]) async throws -> [String: Any] {
    var request = URLRequest(url: tokenURL)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = formBody(fields)
    let (data, response) = try await URLSession.shared.data(for: request)
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      let code = (json["error"] as? String) ?? ((json["error"] as? [String: Any])?["code"] as? String) ?? "http"
      throw AuthError.server(code)
    }
    return json
  }

  /// Checks the ID token's claims and returns the email in it.
  ///
  /// The signature is not verified against OpenAI's JWKS: the token comes
  /// straight from the token endpoint over TLS, which OpenID Connect Core
  /// (3.1.3.7) accepts in place of the signature check for this case.
  private static func checkIDToken(_ token: String?, clientId: String, nonce: String) throws -> String? {
    guard let token else { return nil }
    let parts = token.split(separator: ".")
    guard parts.count == 3, let payload = Data(base64URL: String(parts[1])),
          let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
    else { throw AuthError.invalidIDToken }
    let audience = (claims["aud"] as? String).map { [$0] } ?? (claims["aud"] as? [String]) ?? []
    let expiry = (claims["exp"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? .distantPast
    guard (claims["iss"] as? String)?.hasPrefix("https://auth.openai.com") == true,
          audience.contains(clientId),
          claims["nonce"] as? String == nonce,
          expiry > Date()
    else { throw AuthError.invalidIDToken }
    return claims["email"] as? String
  }

  static func formBody(_ fields: [String: String]) -> Data {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return Data(fields.map { key, value in
      "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
    }.joined(separator: "&").utf8)
  }

  private static func randomURLSafe(_ bytes: Int) -> String {
    var buffer = [UInt8](repeating: 0, count: bytes)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buffer)
    return Data(buffer).base64URL
  }
}

// MARK: - Sign-in sheet

/// Shows OpenAI's sign-in page in a system web sheet and waits for the
/// loopback callback. The sheet's own completion only matters if the user
/// closes it; on success it is closed by us once the code has arrived.
@MainActor
private final class WebSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
  private var session: ASWebAuthenticationSession?

  static func run(url: URL, until callback: @escaping () async throws -> [String: String]) async throws -> [String: String] {
    let presenter = WebSignIn()
    return try await withThrowingTaskGroup(of: [String: String].self) { group in
      group.addTask { try await callback() }
      group.addTask { @MainActor in
        try await presenter.show(url)
        throw ChatGPTAuth.AuthError.cancelled
      }
      defer {
        presenter.session?.cancel()
        group.cancelAll()
      }
      guard let result = try await group.next() else { throw ChatGPTAuth.AuthError.cancelled }
      return result
    }
  }

  /// Returns when the sheet closes. The loopback never matches the "genio"
  /// scheme, so this only ends by the user closing it or by cancel().
  private func show(_ url: URL) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let session = ASWebAuthenticationSession(url: url, callback: .customScheme("genio")) { _, error in
        continuation.resume(throwing: error ?? ChatGPTAuth.AuthError.cancelled)
      }
      session.presentationContextProvider = self
      // Keep Safari's cookies: if you are already logged in to ChatGPT there,
      // you only have to confirm.
      session.prefersEphemeralWebBrowserSession = false
      self.session = session
      if !session.start() {
        continuation.resume(throwing: ChatGPTAuth.AuthError.cancelled)
      }
    }
  }

  nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    MainActor.assumeIsolated {
      UIApplication.shared.connectedScenes
        .compactMap { ($0 as? UIWindowScene)?.keyWindow }
        .first ?? ASPresentationAnchor()
    }
  }
}

// MARK: - Loopback listener

/// A one-shot HTTP listener on 127.0.0.1 that captures the OAuth redirect's
/// query parameters and shows a "go back to Genio" page.
private final class LoopbackListener: @unchecked Sendable {
  let port: UInt16
  private let listener: NWListener
  private let path: String
  private let queue = DispatchQueue(label: "genio.loopback")
  private var continuation: CheckedContinuation<[String: String], Error>?
  private var result: Result<[String: String], Error>?

  private init(listener: NWListener, port: UInt16, path: String) {
    self.listener = listener
    self.port = port
    self.path = path
  }

  /// Binds the first free port of `ports` on 127.0.0.1 only.
  static func start(ports: [UInt16], path: String) async throws -> LoopbackListener {
    var lastError = "no free port"
    for port in ports {
      do {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        let nwListener = try NWListener(using: parameters)
        let loopback = LoopbackListener(listener: nwListener, port: port, path: path)
        try await loopback.waitUntilReady()
        return loopback
      } catch {
        lastError = error.localizedDescription
      }
    }
    throw ChatGPTAuth.AuthError.listener(lastError)
  }

  private func waitUntilReady() async throws {
    try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
      var resumed = false
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          if !resumed { resumed = true; ready.resume() }
        case .failed(let error), .waiting(let error):
          // Waiting usually means the port is taken: try the next one.
          if !resumed { resumed = true; ready.resume(throwing: error) }
        default:
          break
        }
      }
      listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
      listener.start(queue: queue)
    }
  }

  /// Waits for the redirect and returns its query parameters.
  func callback() async throws -> [String: String] {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: String], Error>) in
        queue.async {
          if let result = self.result {
            continuation.resume(with: result)
          } else {
            self.continuation = continuation
          }
        }
      }
    } onCancel: {
      self.finish(.failure(CancellationError()))
    }
  }

  func stop() {
    listener.cancel()
  }

  private func finish(_ outcome: Result<[String: String], Error>) {
    queue.async {
      guard self.result == nil else { return }
      self.result = outcome
      self.continuation?.resume(with: outcome)
      self.continuation = nil
    }
  }

  private func handle(_ connection: NWConnection) {
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
      guard let self else { return }
      let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
      // "GET /auth/callback?code=...&state=... HTTP/1.1"
      let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
      let components = URLComponents(string: "http://127.0.0.1\(target)")
      let isCallback = components?.path == self.path
      let page = isCallback
        ? "<h2>" + String(localized: "Done.") + "</h2><p>" + String(localized: "You can go back to Genio.") + "</p>"
        : "<p>Genio: unknown page.</p>"
      let body = "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width'><body style='font-family:-apple-system;text-align:center;padding-top:30vh'>\(page)</body>"
      let response = "HTTP/1.1 \(isCallback ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(Data(body.utf8).count)\r\nConnection: close\r\n\r\n\(body)"
      connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
      guard isCallback, let items = components?.queryItems else { return }
      var parameters: [String: String] = [:]
      for item in items { parameters[item.name] = item.value ?? "" }
      self.finish(.success(parameters))
    }
  }
}

// MARK: - base64url

extension Data {
  var base64URL: String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  init?(base64URL: String) {
    var text = base64URL
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    while text.count % 4 != 0 { text += "=" }
    self.init(base64Encoded: text)
  }
}
