import Foundation

/// The language Genio speaks and listens in: its spoken lines, the step
/// commands it understands, the speech-synthesis voice and the language the
/// model is asked to answer in. "Automatic" follows the iPhone's language.
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

  /// BCP-47 code for the speech-synthesis voice.
  var voiceCode: String {
    switch self {
    case .italian: return "it-IT"
    case .english: return "en-US"
    }
  }

  /// How the prompts name the language the model must answer in.
  var promptName: String {
    switch self {
    case .italian: return "Italian"
    case .english: return "English"
    }
  }

  // MARK: - Commands (exact phrases, normalized: lowercase, no accents)

  /// What recognisers may write for "Genio".
  var wakeWords: Set<String> {
    switch self {
    case .italian: return ["genio"]
    case .english: return ["genio", "genie", "geno"]
    }
  }

  var stopWords: Set<String> {
    switch self {
    case .italian: return ["stop", "basta", "pausa", "fermati", "ho finito"]
    case .english: return ["stop", "pause", "enough", "that s all", "i m done"]
    }
  }

  var nextWords: Set<String> {
    switch self {
    case .italian: return ["fatto", "ok fatto", "ho fatto", "avanti", "vai avanti", "prossimo", "finito", "e ora", "e adesso"]
    case .english: return ["done", "ok done", "i m done with it", "next", "go on", "finished", "what now", "what s next"]
    }
  }

  var repeatWords: Set<String> {
    switch self {
    case .italian: return ["ripeti", "ripetilo", "come", "cosa"]
    case .english: return ["repeat", "again", "say again", "what", "sorry"]
    }
  }

  var backWords: Set<String> {
    switch self {
    case .italian: return ["indietro", "torna indietro", "passo precedente"]
    case .english: return ["back", "go back", "previous step"]
    }
  }

  var newTaskWords: Set<String> {
    switch self {
    case .italian: return ["nuovo compito", "ricomincia", "cambia compito"]
    case .english: return ["new task", "start over", "change task"]
    }
  }

  // MARK: - Spoken lines

  enum Line {
    case awake
    case resume(goal: String, step: Int, text: String)
    case goodbye
    case tellMe
    case planning
    case notUnderstood
    case planReady(goal: String, count: Int, first: String)
    case step(Int, String)
    case allDone(goal: String)
    case whatNow
    case noClaudeKey
    case notSignedIn
    case usageLimit
    case unreachable
  }

  func say(_ line: Line) -> String {
    switch (self, line) {
    case (.italian, .awake): return "Genio attivo. Cosa facciamo?"
    case (.english, .awake): return "Genio here. What are we doing?"
    case (.italian, .resume(let goal, let step, let text)): return "Riprendiamo \(goal). Passo \(step): \(text)"
    case (.english, .resume(let goal, let step, let text)): return "Back to \(goal). Step \(step): \(text)"
    case (.italian, .goodbye): return "Ok, a dopo."
    case (.english, .goodbye): return "Okay, talk later."
    case (.italian, .tellMe): return "Dimmi"
    case (.english, .tellMe): return "Yes?"
    case (.italian, .planning): return "Ok, preparo i passi."
    case (.english, .planning): return "Okay, working out the steps."
    case (.italian, .notUnderstood): return "Non ho capito il compito. Ripetilo?"
    case (.english, .notUnderstood): return "I didn't get the task. Can you say it again?"
    case (.italian, .planReady(let goal, let count, let first)): return "\(goal): \(count) passi. Primo: \(first)"
    case (.english, .planReady(let goal, let count, let first)): return "\(goal): \(count) steps. First: \(first)"
    case (.italian, .step(let number, let text)): return "Passo \(number): \(text)"
    case (.english, .step(let number, let text)): return "Step \(number): \(text)"
    case (.italian, .allDone(let goal)): return "Fatto tutto, \(goal) completato!"
    case (.english, .allDone(let goal)): return "All done, \(goal) complete!"
    case (.italian, .whatNow): return "Ok. Cosa facciamo?"
    case (.english, .whatNow): return "Okay. What are we doing?"
    case (.italian, .noClaudeKey): return "Manca la chiave di Claude nelle impostazioni."
    case (.english, .noClaudeKey): return "The Claude key is missing in Settings."
    case (.italian, .notSignedIn): return "Devi accedere con ChatGPT nelle impostazioni."
    case (.english, .notSignedIn): return "Please sign in with ChatGPT in Settings."
    case (.italian, .usageLimit): return "Hai finito l'uso del piano ChatGPT per ora."
    case (.english, .usageLimit): return "Your ChatGPT plan's usage is used up for now."
    case (.italian, .unreachable): return "Non riesco a contattare il modello adesso."
    case (.english, .unreachable): return "I can't reach the model right now."
    }
  }
}
