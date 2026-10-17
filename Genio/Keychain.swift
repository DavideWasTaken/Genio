import Foundation
import Security

/// Secrets kept in the iOS Keychain (never in the source code): the Claude
/// API key and the ChatGPT sign-in tokens.
enum Keychain {
  // Kept from the first version, so an API key already saved still reads back.
  private static let service = "genio.anthropic"

  static var apiKey: String? {
    get { string("apiKey") }
    set { set(newValue.map { Data($0.utf8) }, for: "apiKey") }
  }

  static func string(_ account: String) -> String? {
    data(account).flatMap { String(data: $0, encoding: .utf8) }
  }

  static func data(_ account: String) -> Data? {
    var query = baseQuery(account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
    return item as? Data
  }

  /// Stores `value` under `account`; nil or empty deletes it.
  static func set(_ value: Data?, for account: String) {
    SecItemDelete(baseQuery(account) as CFDictionary)
    guard let value, !value.isEmpty else { return }
    var query = baseQuery(account)
    query[kSecValueData as String] = value
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemAdd(query as CFDictionary, nil)
  }

  private static func baseQuery(_ account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}
