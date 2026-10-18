import AVFoundation
import GenioCore

/// The one place that configures the audio session and owns the audio
/// engine, so the classic voice (AVSpeechSynthesizer + chimes), Gemini Live
/// (microphone in, voice out) and the glasses' own speech recognition do not
/// fight over the hardware.
///
///  - Classic: playback only (A2DP "media" or HFP "call"); the glasses
///    transcribe speech themselves (DAT Speech) and iOS speaks.
///  - Live: play-and-record over the Bluetooth hands-free profile, so the
///    glasses' microphone feeds Gemini and Gemini's voice plays on the
///    glasses; voice processing cancels Genio's own voice from the mic.
///  - Standby: glasses connected, GENIO off. Silent playback, mixed with
///    other apps, keeps iOS from suspending Genio in the background, so the
///    glasses' button still reaches it.
///
/// The route is checked, never assumed: `route` says which microphone and
/// speaker iOS actually picked, and `micIsGlasses` is false when the phone's
/// own microphone is in use.
@MainActor
final class AudioManager: ObservableObject {
  enum Mode: Equatable {
    case idle
    case classic(Voice.Route)
    case live
    case standby
  }

  struct RouteInfo: Equatable {
    var input = "–"
    var output = "–"
    var inputIsBluetooth = false
    var outputIsBluetooth = false
    var sampleRate: Double = 0
  }

  @Published private(set) var mode: Mode = .idle
  @Published private(set) var route = RouteInfo()
  /// Microphone level (0…1) while capturing, for the test meter.
  @Published private(set) var inputLevel: Float = 0
  @Published private(set) var lastError: String?

  var micIsGlasses: Bool { route.inputIsBluetooth }

  /// 16 kHz 16-bit mono PCM chunks from the microphone (Live mode). Called
  /// on the audio thread. Set it before configureLive().
  var onMicrophonePCM: (@Sendable (Data) -> Void)?
  /// Diagnostics for the in-app log.
  var onLog: ((String) -> Void)?

  private var engine = AVAudioEngine()
  private let tonePlayer = AVAudioPlayerNode()
  private let voicePlayer = AVAudioPlayerNode()
  /// Plays silence in a loop in standby.
  private let keepAlivePlayer = AVAudioPlayerNode()
  private let toneFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
  /// Gemini Live's output: 24 kHz mono.
  private let voiceFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
  private var capturing = false
  private var observers: [NSObjectProtocol] = []
  /// Seconds of Gemini audio scheduled and not yet played.
  private var queuedVoiceBuffers = 0

  init() {
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
      let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
      MainActor.assumeIsolated { self?.routeChanged(reason) }
    })
    observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
      let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
      MainActor.assumeIsolated { self?.interrupted(type) }
    })
    observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.mediaServicesReset() }
    })
    observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.restartEngineIfNeeded() }
    })
  }

  // MARK: - Modes

  /// The classic voice: iOS speaks, the glasses listen.
  func configureClassic(route: Voice.Route) {
    stopCapture()
    let session = AVAudioSession.sharedInstance()
    do {
      switch route {
      case .media:
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
      case .call:
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .duckOthers])
      }
      try session.setActive(true)
      lastError = nil
    } catch {
      report("audio session (classic): \(error.localizedDescription)")
    }
    if mode != .classic(route) { rebuildEngine() }
    mode = .classic(route)
    refreshRoute()
  }

  /// Gemini Live: two-way audio over the glasses' hands-free profile.
  /// Returns false (with `lastError`) if the microphone cannot start.
  func configureLive() async -> Bool {
    guard await AVAudioApplication.requestRecordPermission() else {
      report("Microphone permission denied: Settings → Genio → Microphone.")
      return false
    }
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
      try session.setPreferredSampleRate(16_000)
      try session.setPreferredIOBufferDuration(0.02)
      try session.setActive(true)
      lastError = nil
    } catch {
      report("audio session (live): \(error.localizedDescription)")
      return false
    }
    if mode != .live { rebuildEngine() }
    mode = .live
    refreshRoute()
    if !route.inputIsBluetooth {
      report("The microphone is \(route.input), not the glasses: Gemini will hear the phone. Check that the glasses are connected as Bluetooth audio.")
    }
    return startCapture()
  }

  /// Glasses connected, GENIO off: silent playback that keeps iOS from
  /// suspending the app, so the glasses' button still works with Genio in
  /// the background. Mixed with other apps: music is not interrupted.
  func configureStandby() {
    guard mode != .standby else { return }
    stopCapture()
    flushVoice()
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      try session.setActive(true)
      lastError = nil
    } catch {
      report("audio session (standby): \(error.localizedDescription)")
      return
    }
    rebuildEngine()
    mode = .standby
    refreshRoute()
    if startKeepAlive() {
      onLog?("Audio: standby, so the glasses' button works with Genio in the background")
    }
  }

  func deactivate() {
    stopCapture()
    flushVoice()
    keepAlivePlayer.stop()
    engine.stop()
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    mode = .idle
  }

  // MARK: - Playback

  func playChime(_ buffer: AVAudioPCMBuffer) {
    guard startEngine() else { return }
    tonePlayer.scheduleBuffer(buffer)
    tonePlayer.play()
  }

  /// Gemini's voice: 24 kHz 16-bit mono PCM.
  func playVoice(pcm24k data: Data) {
    let samples = PCM.floatSamples(fromInt16: data)
    guard !samples.isEmpty, startEngine(),
          let buffer = AVAudioPCMBuffer(pcmFormat: voiceFormat, frameCapacity: AVAudioFrameCount(samples.count)),
          let channel = buffer.floatChannelData?[0]
    else { return }
    samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    queuedVoiceBuffers += 1
    voicePlayer.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.queuedVoiceBuffers = max(0, self.queuedVoiceBuffers - 1)
      }
    }
    if !voicePlayer.isPlaying { voicePlayer.play() }
  }

  /// Whether Gemini's voice is still playing.
  var isPlayingVoice: Bool { queuedVoiceBuffers > 0 }

  /// Drops Gemini audio not yet played (the user interrupted).
  func flushVoice() {
    voicePlayer.stop()
    queuedVoiceBuffers = 0
  }

  // MARK: - Capture

  private func startCapture() -> Bool {
    guard !capturing else { return true }
    let input = engine.inputNode
    do {
      // Echo cancellation: Genio's voice must not come back as the user's.
      if !input.isVoiceProcessingEnabled { try input.setVoiceProcessingEnabled(true) }
    } catch {
      onLog?("Audio: voice processing unavailable (\(error.localizedDescription)); echo may be heard")
    }
    let inputFormat = input.outputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
          let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
          let converter = AVAudioConverter(from: inputFormat, to: target)
    else {
      report("No usable microphone (format \(inputFormat)).")
      return false
    }
    let chunker = MicChunker(converter: converter, target: target)
    let deliver = onMicrophonePCM
    input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
      guard case let (pcm, level)? = chunker.convert(buffer) else { return }
      deliver?(pcm)
      Task { @MainActor in self?.inputLevel = level }
    }
    capturing = true
    guard startEngine() else {
      input.removeTap(onBus: 0)
      capturing = false
      return false
    }
    onLog?("Audio: microphone \(route.input) at \(Int(inputFormat.sampleRate)) Hz, output \(route.output)")
    return true
  }

  private func stopCapture() {
    guard capturing else { return }
    engine.inputNode.removeTap(onBus: 0)
    capturing = false
    inputLevel = 0
  }

  // MARK: - Engine

  /// A fresh engine per mode: voice processing and the input tap belong to
  /// Live only, and the classic session may have no input at all.
  private func rebuildEngine() {
    stopCapture()
    engine.stop()
    if tonePlayer.engine != nil { engine.detach(tonePlayer) }
    if voicePlayer.engine != nil { engine.detach(voicePlayer) }
    if keepAlivePlayer.engine != nil { engine.detach(keepAlivePlayer) }
    engine = AVAudioEngine()
    engine.attach(tonePlayer)
    engine.connect(tonePlayer, to: engine.mainMixerNode, format: toneFormat)
    engine.attach(voicePlayer)
    engine.connect(voicePlayer, to: engine.mainMixerNode, format: voiceFormat)
    engine.attach(keepAlivePlayer)
    engine.connect(keepAlivePlayer, to: engine.mainMixerNode, format: toneFormat)
  }

  /// One second of silence, looped.
  @discardableResult
  private func startKeepAlive() -> Bool {
    guard startEngine(),
          let silence = AVAudioPCMBuffer(pcmFormat: toneFormat, frameCapacity: AVAudioFrameCount(toneFormat.sampleRate)),
          let channel = silence.floatChannelData?[0]
    else { return false }
    silence.frameLength = silence.frameCapacity
    channel.update(repeating: 0, count: Int(silence.frameLength))
    keepAlivePlayer.stop()
    keepAlivePlayer.scheduleBuffer(silence, at: nil, options: .loops)
    keepAlivePlayer.play()
    return true
  }

  @discardableResult
  private func startEngine() -> Bool {
    if tonePlayer.engine == nil { rebuildEngine() }
    guard !engine.isRunning else { return true }
    do {
      engine.prepare()
      try engine.start()
      return true
    } catch {
      report("audio engine: \(error.localizedDescription)")
      return false
    }
  }

  private func restartEngineIfNeeded() {
    guard mode != .idle, !engine.isRunning else { return }
    onLog?("Audio: engine configuration changed, restarting")
    switch mode {
    case .live:
      stopCapture()
      _ = startCapture()
    case .standby:
      startKeepAlive()
    default:
      startEngine()
    }
  }

  // MARK: - Route and interruptions

  func refreshRoute() {
    let session = AVAudioSession.sharedInstance()
    let bluetooth: Set<AVAudioSession.Port> = [.bluetoothHFP, .bluetoothLE, .bluetoothA2DP]
    let input = session.currentRoute.inputs.first
    let output = session.currentRoute.outputs.first
    route = RouteInfo(
      input: input.map { "\($0.portName) (\($0.portType.rawValue))" } ?? "–",
      output: output.map { "\($0.portName) (\($0.portType.rawValue))" } ?? "–",
      inputIsBluetooth: input.map { bluetooth.contains($0.portType) } ?? false,
      outputIsBluetooth: output.map { bluetooth.contains($0.portType) } ?? false,
      sampleRate: session.sampleRate)
  }

  private func routeChanged(_ reason: AVAudioSession.RouteChangeReason?) {
    let wasGlasses = route.inputIsBluetooth
    refreshRoute()
    onLog?("Audio route: in \(route.input), out \(route.output)")
    if mode == .live, wasGlasses, !route.inputIsBluetooth {
      report("The glasses' microphone went away: now using \(route.input).")
    }
  }

  private func interrupted(_ type: AVAudioSession.InterruptionType?) {
    switch type {
    case .began:
      onLog?("Audio: interrupted (call, Siri, alarm)")
    case .ended:
      try? AVAudioSession.sharedInstance().setActive(true)
      restartEngineIfNeeded()
    default:
      break
    }
  }

  private func mediaServicesReset() {
    onLog?("Audio: media services were reset, rebuilding")
    let current = mode
    mode = .idle
    rebuildEngine()
    switch current {
    case .classic(let route): configureClassic(route: route)
    case .live: Task { _ = await configureLive() }
    case .standby: configureStandby()
    case .idle: break
    }
  }

  private func report(_ message: String) {
    lastError = message
    onLog?("Audio: \(message)")
  }
}

/// Converts microphone buffers to 16 kHz 16-bit mono and hands them out in
/// ~64 ms chunks. Used only on the audio thread.
private final class MicChunker: @unchecked Sendable {
  private let converter: AVAudioConverter
  private let target: AVAudioFormat
  private var pending = Data()
  private let chunkBytes = 2048  // 1024 samples = 64 ms at 16 kHz

  init(converter: AVAudioConverter, target: AVAudioFormat) {
    self.converter = converter
    self.target = target
  }

  /// A full chunk and its level, or nil while still filling.
  func convert(_ buffer: AVAudioPCMBuffer) -> (Data, Float)? {
    let ratio = target.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
    guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
    var supplied = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
      if supplied {
        status.pointee = .noDataNow
        return nil
      }
      supplied = true
      status.pointee = .haveData
      return buffer
    }
    guard error == nil, output.frameLength > 0, let channel = output.int16ChannelData?[0] else { return nil }
    pending.append(Data(bytes: channel, count: Int(output.frameLength) * 2))
    guard pending.count >= chunkBytes else { return nil }
    let chunk = pending
    pending = Data()
    return (chunk, PCM.level(ofInt16: chunk))
  }
}
