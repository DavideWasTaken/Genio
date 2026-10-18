import Foundation

/// "Genio stop" and its variants, recognised directly in the microphone
/// transcript so that switching off by voice does not depend on the model
/// choosing to call pause_guidance. Only phrases that name Genio count:
/// a bare "stop" or "basta" may be meant for someone else (the model still
/// handles those through the function).
public enum VoiceStop {
  /// Pairs of consecutive words, after accents and case are folded.
  static let phrases: [[String]] = [
    ["genio", "stop"], ["stop", "genio"],
    ["genio", "basta"], ["basta", "genio"],
    ["genio", "fermati"], ["ferma", "genio"], ["fermati", "genio"],
    ["genio", "pausa"], ["pausa", "genio"],
    ["genio", "spegniti"], ["spegni", "genio"],
    ["genio", "pause"], ["genie", "stop"], ["stop", "genie"],
  ]

  public static func matches(_ transcript: String) -> Bool {
    let words = TaskTools.normalizedWords(transcript)
    guard words.count >= 2 else { return false }
    for index in 0..<(words.count - 1) {
      let pair = [words[index], words[index + 1]]
      if phrases.contains(pair) { return true }
    }
    return false
  }
}
