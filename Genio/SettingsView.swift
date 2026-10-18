import GenioCore
import SwiftUI
import UIKit

/// Settings: Gemini Live (key, model, voice, video), the vision coach,
/// language, the glasses button, audio and camera tests, diagnostics.
struct SettingsView: View {
  @ObservedObject var genio: GenioController
  @ObservedObject var glasses: GlassesManager
  @ObservedObject var live: LiveConversationEngine
  @Environment(\.dismiss) private var dismiss
  @AppStorage(SettingKey.coachInterval) private var coachInterval = 6.0
  @AppStorage(SettingKey.coachEnabled) private var coachEnabled = true
  @AppStorage(SettingKey.coachModel) private var coachModel = ""
  @AppStorage(SettingKey.pressType) private var pressType = "shortPress"
  @AppStorage(SettingKey.geminiModel) private var geminiModel = LiveConversationEngine.defaultModel
  @AppStorage(SettingKey.geminiVoice) private var geminiVoice = LiveConversationEngine.defaultVoice
  @AppStorage(SettingKey.geminiFramesPerSecond) private var framesPerSecond = 1.0
  @AppStorage(VoiceLanguage.settingKey) private var voiceLanguage = VoiceLanguage.automatic
  @State private var apiKey = Keychain.geminiKey ?? ""
  @State private var liveModels: [String] = []
  @State private var coachModels: [String] = []
  @State private var modelsError: String?

  var body: some View {
    NavigationStack {
      Form {
        geminiSection
        if genio.active { statusSection }
        coachSection

        Section {
          Picker("Voice language", selection: $voiceLanguage) {
            Text("Automatic (iPhone)").tag(VoiceLanguage.automatic)
            ForEach(VoiceLanguage.allCases) { Text(verbatim: $0.displayName).tag($0.rawValue) }
          }
          Button("App language") {
            if let url = URL(string: UIApplication.openSettingsURLString) {
              UIApplication.shared.open(url)
            }
          }
        } header: {
          Text("Language")
        } footer: {
          Text("The voice language is what Genio speaks and answers in. The app's screens follow the iPhone's language; to change them for Genio only, open App language.")
        }

        Section {
          Picker("Start/stop button", selection: $pressType) {
            Text("Short press").tag("shortPress")
            Text("Double press").tag("doublePress")
            Text("Long press").tag("hold")
          }
          NavigationLink {
            HardwareTestView(genio: genio, glasses: glasses, audio: genio.audio)
          } label: {
            Label("Test audio and camera", systemImage: "waveform.and.mic")
          }
          .disabled(genio.active)
        } header: {
          Text("Glasses")
        } footer: {
          if genio.active {
            Text("Switch GENIO off to run the tests.")
          }
        }

        Section("Diagnostics") {
          NavigationLink {
            LogView(genio: genio)
          } label: {
            LabeledContent("Log") {
              Text("\(genio.log.count) lines")
            }
          }
          ForEach(glasses.deviceLines, id: \.self) { line in
            Label(line, systemImage: "eyeglasses")
              .font(.footnote)
          }
        }

        Section {
          LabeledContent("Version") {
            Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
          }
          Link(destination: URL(string: "https://github.com/DavideWasTaken/Genio")!) {
            Label("Source code on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
          }
        } header: {
          Text("About")
        }
      }
      .navigationTitle("Settings")
      .task { await loadModels() }
      .onChange(of: apiKey) { _, newValue in
        Keychain.geminiKey = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.removeObject(forKey: SettingKey.coachModelResolved)
      }
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .tint(Color.genioViolet)
  }

  // MARK: - Sections

  private var geminiSection: some View {
    Section {
      SecureField(text: $apiKey) { Text(verbatim: "AIza…") }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      Picker("Realtime model", selection: $geminiModel) {
        ForEach(Self.withCurrent(liveModels, geminiModel, default: LiveConversationEngine.defaultModel), id: \.self) {
          Text(verbatim: $0).tag($0)
        }
      }
      Picker("Voice", selection: $geminiVoice) {
        ForEach(LiveConversationEngine.voices, id: \.self) { Text(verbatim: $0).tag($0) }
      }
      VStack(alignment: .leading) {
        Text("Video: \(framesPerSecond, specifier: "%.1f") frames per second")
        Slider(value: $framesPerSecond, in: 0.2...1, step: 0.1)
      }
      if let modelsError {
        Text(verbatim: modelsError)
          .font(.footnote)
          .foregroundStyle(Color.orange)
      }
    } header: {
      Text("Gemini Live")
    } footer: {
      Text("A Gemini API key from aistudio.google.com. It stays in this iPhone's keychain. Changes apply the next time GENIO starts. Fewer frames per second use fewer tokens; the coach still looks every few seconds.")
    }
  }

  private var statusSection: some View {
    Section {
      LabeledContent("Connection") {
        Text(statusText)
          .foregroundStyle(statusColor)
      }
      LabeledContent("Microphone") {
        Text(verbatim: genio.audio.route.input)
          .foregroundStyle(genio.audio.micIsGlasses ? Color.primary : Color.orange)
      }
      LabeledContent("Frames sent") {
        Text("\(live.metrics.framesSent) (dropped \(live.metrics.framesDropped), \(Int(live.metrics.frameLatency * 1000)) ms)")
      }
      LabeledContent("Session") {
        Text("\(Int(live.metrics.connectedSeconds / 60)) min · \(live.metrics.totalTokens) tokens")
      }
    } header: {
      Text("Now")
    } footer: {
      Text("Tokens as reported by Gemini for this session. Prices: ai.google.dev/pricing.")
    }
  }

  private var coachSection: some View {
    Section {
      Toggle("Vision coach", isOn: $coachEnabled)
      if coachEnabled {
        Stepper("Looks every \(Int(coachInterval)) s", value: $coachInterval, in: 3...30, step: 1)
        Picker("Coach model", selection: $coachModel) {
          Text("Automatic").tag("")
          ForEach(Self.withCurrent(coachModels, coachModel, default: nil), id: \.self) { Text(verbatim: $0).tag($0) }
        }
      }
    } header: {
      Text("Coach")
    } footer: {
      Text("A second, fast Gemini model looks at the camera every few seconds to check the step and spot mistakes, besides the conversation. A step moves on only after consistent evidence. Off: only the conversation checks, with fewer calls. Genio is not a safety device.")
    }
  }

  // MARK: - Helpers

  private var statusText: String {
    switch live.status {
    case .off: return String(localized: "Off")
    case .connecting: return String(localized: "Connecting…")
    case .live: return String(localized: "Live")
    case .reconnecting(let attempt): return String(localized: "Reconnecting (\(attempt))…")
    case .failed(let why): return why
    }
  }

  private var statusColor: Color {
    switch live.status {
    case .live: return .green
    case .failed: return .red
    case .connecting, .reconnecting: return .orange
    case .off: return .secondary
    }
  }

  private func loadModels() async {
    let key = Keychain.geminiKey ?? ""
    guard !key.isEmpty else { return }
    do {
      liveModels = try await GeminiVisionCoach.listModels(apiKey: key, method: "bidiGenerateContent")
      coachModels = try await GeminiVisionCoach.listModels(apiKey: key)
        .filter { $0.contains("flash") || $0.contains("pro") }
      modelsError = nil
    } catch {
      modelsError = String(localized: "Models unavailable: \(error.localizedDescription)")
    }
  }

  /// The list with the current choice (and the default) always present.
  private static func withCurrent(_ list: [String], _ current: String, default fallback: String?) -> [String] {
    var result = list
    for item in [fallback, current].compactMap({ $0 }) where !item.isEmpty && !result.contains(item) {
      result.insert(item, at: 0)
    }
    return result
  }
}

/// Checks the hardware before relying on it: which microphone and speaker
/// iOS actually uses (the glasses' over Bluetooth, or the phone's), the mic
/// level, a chime on the speaker, and a fresh camera frame.
struct HardwareTestView: View {
  @ObservedObject var genio: GenioController
  @ObservedObject var glasses: GlassesManager
  @ObservedObject var audio: AudioManager
  @State private var testingAudio = false
  @State private var frame: (UIImage, TimeInterval)?

  var body: some View {
    Form {
      Section {
        if testingAudio {
          LabeledContent("Microphone") { Text(verbatim: audio.route.input) }
          LabeledContent("Speaker") { Text(verbatim: audio.route.output) }
          ProgressView(value: Double(min(1, audio.inputLevel * 4)))
            .tint(audio.micIsGlasses ? Color.green : Color.orange)
          if !audio.micIsGlasses {
            Text("The microphone is not the glasses: check that they are connected as Bluetooth audio in iOS Settings.")
              .font(.footnote)
              .foregroundStyle(Color.orange)
          }
          Button("Stop the audio test") { stopAudio() }
        } else {
          Button("Start the audio test") { Task { await startAudio() } }
        }
        if let error = audio.lastError {
          Text(verbatim: error)
            .font(.footnote)
            .foregroundStyle(Color.red)
        }
      } header: {
        Text("Audio")
      } footer: {
        Text("Speak: the bar should move. You should hear a chime on the glasses. This uses the same two-way Bluetooth audio as Gemini Live.")
      }

      Section {
        if case let (image, age)? = frame {
          Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 8))
          Text("Frame from \(age, specifier: "%.1f") s ago")
            .font(.footnote)
            .foregroundStyle(age < 2 ? Color.secondary : Color.orange)
        } else {
          Text(glasses.status == .streaming ? "No frame yet." : "Connect the glasses first.")
            .foregroundStyle(.secondary)
        }
        Button("Take a frame") { frame = glasses.latestImage() }
          .disabled(glasses.status != .streaming)
      } header: {
        Text("Camera")
      }
    }
    .navigationTitle("Test audio and camera")
    .navigationBarTitleDisplayMode(.inline)
    .onDisappear { stopAudio() }
  }

  private func startAudio() async {
    audio.onMicrophonePCM = nil
    testingAudio = await audio.configureLive()
    if let chime = Voice.chimeBuffer(.on) { audio.playChime(chime) }
  }

  private func stopAudio() {
    guard testingAudio else { return }
    testingAudio = false
    if !genio.active { audio.deactivate() }
  }
}

/// What Genio heard, said and ran into, newest first. "Copy" puts it all on
/// the clipboard, ready to paste into a bug report.
struct LogView: View {
  @ObservedObject var genio: GenioController

  var body: some View {
    List {
      if genio.log.isEmpty {
        Text("Nothing yet: connect the glasses or start GENIO.")
          .foregroundStyle(.secondary)
      }
      ForEach(Array(genio.log.reversed().enumerated()), id: \.offset) { _, line in
        Text(verbatim: line)
          .font(.system(.footnote, design: .monospaced))
          .textSelection(.enabled)
      }
    }
    .navigationTitle("Log")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("Copy") {
          UIPasteboard.general.string = genio.log.joined(separator: "\n")
        }
        .disabled(genio.log.isEmpty)
      }
    }
  }
}
