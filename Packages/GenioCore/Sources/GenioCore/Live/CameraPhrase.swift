import Foundation

/// "Accendo la fotocamera" and its variants, recognised in Genio's own
/// transcript. Gemini sometimes says it turns the camera on without calling
/// turn_on_camera: the app then turns it on itself, so Genio never says it
/// and leaves the camera off.
public enum CameraPhrase {
  /// Verbs of turning on, as Genio says them about itself.
  static let verbs: Set<String> = [
    "accendo", "accendiamo", "accendendo", "riaccendo", "attivo", "attiviamo", "attivando", "riattivo",
    "turning", "turn", "switching", "switch",
  ]
  /// English verbs need "on" in the same phrase ("turning the camera off" is not it).
  static let englishVerbs: Set<String> = ["turning", "turn", "switching", "switch"]
  static let nouns: Set<String> = ["fotocamera", "camera", "videocamera", "telecamera"]
  /// How far after the verb the camera may come: "accendo subito la
  /// fotocamera", "turning on the camera", but not "accendo la luce in camera".
  static let window = 3

  public static func announcesCameraOn(_ transcript: String) -> Bool {
    let words = TaskTools.normalizedWords(transcript)
    for (index, word) in words.enumerated() where verbs.contains(word) {
      let phrase = words[(index + 1)..<min(words.count, index + 1 + window)]
      guard let noun = phrase.firstIndex(where: nouns.contains) else { continue }
      if englishVerbs.contains(word) {
        // "on" between the verb and the camera, or right after it.
        let around = words[(index + 1)..<min(words.count, noun + 2)]
        guard around.contains("on"), !around.contains("off") else { continue }
      }
      return true
    }
    return false
  }
}
