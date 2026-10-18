import Foundation

/// A line for the in-app Log (Settings → Log; also printed to the
/// Xcode console) from code that has no handle on the controller. Safe from
/// any thread or actor.
enum GenioLog {
  static let notification = Notification.Name("GenioLog")

  static func post(_ line: String) {
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: notification, object: nil, userInfo: ["line": line])
    }
  }
}
