import Foundation

/// The language Genio speaks and listens in: the language Gemini is told to
/// use, and the iOS voice for the few lines Genio says when Gemini cannot
/// (no key, no connection). "Automatic" follows the iPhone's language.
///
/// The screens follow the iPhone's language on their own (or the per-app
/// language in iOS Settings → Genio); this is only the voice.
enum VoiceLanguage: String, CaseIterable, Identifiable {
  case italian = "it"
  case english = "en"

  var id: String { rawValue }

  static let settingKey = "voiceLanguage"
  static let automatic = "auto"

  /// The language in use now: the saved choice, or the iPhone's language
  /// when the choice is "auto" (Italian if it is Italian, English otherwise).
  static var current: VoiceLanguage {
    let saved = UserDefaults.standard.string(forKey: settingKey) ?? automatic
    if let chosen = VoiceLanguage(rawValue: saved) { return chosen }
    let phone = Locale.preferredLanguages.first ?? "en"
    return phone.hasPrefix("it") ? .italian : .english
  }

  /// Name shown in the picker, in its own language.
  var displayName: String {
    switch self {
    case .italian: return "Italiano"
    case .english: return "English"
    }
  }

  /// BCP-47 code for the iOS voice.
  var voiceCode: String {
    switch self {
    case .italian: return "it-IT"
    case .english: return "en-US"
    }
  }

  /// How the instructions name the language Gemini must speak.
  var promptName: String {
    switch self {
    case .italian: return "Italian"
    case .english: return "English"
    }
  }

  // MARK: - Lines said in the iOS voice

  enum Line {
    case noGeminiKey
    case unreachable
    case microphoneUnavailable
  }

  func say(_ line: Line) -> String {
    switch (self, line) {
    case (.italian, .noGeminiKey): return "Manca la chiave di Gemini nelle impostazioni."
    case (.english, .noGeminiKey): return "The Gemini key is missing in Settings."
    case (.italian, .unreachable): return "Non riesco a contattare Gemini adesso."
    case (.english, .unreachable): return "I can't reach Gemini right now."
    case (.italian, .microphoneUnavailable): return "Non riesco ad aprire il microfono. Apri Genio sul telefono e riprova."
    case (.english, .microphoneUnavailable): return "I can't open the microphone. Open Genio on the phone and try again."
    }
  }
}
