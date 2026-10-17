import Foundation

/// A line for the in-app Log (Settings → Diagnostics) from code that has no
/// handle on the controller, such as the ChatGPT sign-in. Safe from any
/// thread or actor.
enum GenioLog {
  static let notification = Notification.Name("GenioLog")

  static func post(_ line: String) {
    NSLog("[Genio] %@", line)
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: notification, object: nil, userInfo: ["line": line])
    }
  }
}
