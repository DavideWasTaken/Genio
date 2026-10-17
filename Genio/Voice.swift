import AVFoundation

/// Genio's voice: Italian speech synthesis plus two short chimes (on / off),
/// played through whatever audio route iOS picks -- the glasses' speakers
/// when they are connected as Bluetooth audio.
@MainActor
final class Voice: NSObject, AVSpeechSynthesizerDelegate {
  enum Route: String, CaseIterable, Identifiable {
    /// Bluetooth media profile (A2DP): best quality, does not take the mic.
    case media
    /// Hands-free profile (HFP), like a phone call: lower quality, but it
    /// stays on the glasses if camera streaming pushes media audio off.
    case call

    var id: String { rawValue }
    var label: String {
      self == .media ? String(localized: "Media (better quality)") : String(localized: "Call (steadier)")
    }
  }

  /// Wake and sleep cues: a rising and a falling C-major arpeggio.
  enum Chime {
    case on, off

    /// (frequency in Hz, seconds); 0 Hz is a short rest.
    fileprivate var notes: [(Double, Double)] {
      let arpeggio: [(Double, Double)] = [(523.25, 0.08), (0, 0.015), (659.25, 0.08), (0, 0.015), (783.99, 0.14)]
      return self == .on ? arpeggio : Array(arpeggio.reversed())
    }
  }

  private let synthesizer = AVSpeechSynthesizer()
  private let engine = AVAudioEngine()
  private let tonePlayer = AVAudioPlayerNode()
  private let toneFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
  private var waiting: [ObjectIdentifier: CheckedContinuation<Void, Never>] = [:]

  /// True while a line is being spoken or queued.
  private(set) var isSpeaking = false

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  func configure(route: Route) {
    let session = AVAudioSession.sharedInstance()
    do {
      switch route {
      case .media:
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
      case .call:
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .duckOthers])
      }
      try session.setActive(true)
    } catch {
      NSLog("[Voice] audio session: %@", error.localizedDescription)
    }
  }

  /// Speaks `text` and returns when it has been said (or interrupted).
  func speak(_ text: String, languageCode: String) async {
    let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !line.isEmpty else { return }
    let utterance = AVSpeechUtterance(string: line)
    utterance.voice = AVSpeechSynthesisVoice(language: languageCode)
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
    isSpeaking = true
    await withCheckedContinuation { continuation in
      waiting[ObjectIdentifier(utterance)] = continuation
      synthesizer.speak(utterance)
    }
  }

  func stop() {
    synthesizer.stopSpeaking(at: .immediate)
  }

  func chime(_ chime: Chime) {
    if tonePlayer.engine == nil {
      engine.attach(tonePlayer)
      engine.connect(tonePlayer, to: engine.mainMixerNode, format: toneFormat)
    }
    do {
      if !engine.isRunning { try engine.start() }
    } catch {
      NSLog("[Voice] tone engine: %@", error.localizedDescription)
      return
    }
    guard let buffer = Self.tones(chime.notes, format: toneFormat) else { return }
    tonePlayer.scheduleBuffer(buffer)
    tonePlayer.play()
  }

  private func finished(_ id: ObjectIdentifier) {
    waiting.removeValue(forKey: id)?.resume()
    isSpeaking = !waiting.isEmpty
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    let id = ObjectIdentifier(utterance)
    Task { @MainActor in self.finished(id) }
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    let id = ObjectIdentifier(utterance)
    Task { @MainActor in self.finished(id) }
  }

  /// Renders sine notes straight into a PCM buffer, each with a 5 ms ramp
  /// in and out so it starts and stops without a click.
  private static func tones(_ notes: [(Double, Double)], format: AVAudioFormat) -> AVAudioPCMBuffer? {
    let rate = format.sampleRate
    let frames = notes.reduce(0) { $0 + Int($1.1 * rate) }
    guard frames > 0,
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
          let samples = buffer.floatChannelData?[0]
    else { return nil }
    let ramp = rate * 0.005
    var index = 0
    for (frequency, seconds) in notes {
      let count = Int(seconds * rate)
      for n in 0..<count {
        let gain = min(1, Double(n) / ramp, Double(count - n) / ramp)
        let wave = frequency > 0 ? sin(2 * .pi * frequency * Double(n) / rate) : 0
        samples[index] = Float(0.3 * gain * wave)
        index += 1
      }
    }
    buffer.frameLength = AVAudioFrameCount(frames)
    return buffer
  }
}
