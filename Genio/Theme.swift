import SwiftUI

/// Genio's palette, shared with the app icon: a night indigo, a violet and
/// the gold of the "lamp" sparkle.
extension Color {
  static let genioNight = Color(red: 0.12, green: 0.10, blue: 0.32)
  static let genioViolet = Color(red: 0.42, green: 0.25, blue: 0.82)
  static let genioGold = Color(red: 0.98, green: 0.78, blue: 0.27)
}

/// A rounded card on the grouped background.
struct Card<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 14) { content }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(18)
      .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
  }
}

/// A small on/off status capsule: "Camera", "Button", "Voice".
struct StatusPill: View {
  let title: LocalizedStringKey
  let systemImage: String
  let isOn: Bool

  var body: some View {
    Label(title, systemImage: systemImage)
      .font(.caption.weight(.semibold))
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .foregroundStyle(isOn ? Color.green : Color.secondary)
      .background((isOn ? Color.green : Color.secondary).opacity(0.14), in: Capsule())
      .accessibilityValue(isOn ? Text("ready") : Text("not ready"))
  }
}
