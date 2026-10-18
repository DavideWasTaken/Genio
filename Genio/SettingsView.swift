import GenioCore
import SwiftUI
import UIKit

/// Settings: only what changes how Genio works for you. The technical
/// choices (realtime model, coach model and pace, video rate) use sensible
/// defaults; the session's numbers are in the Log.
struct SettingsView: View {
  @ObservedObject var genio: GenioController
  @ObservedObject var glasses: GlassesManager
  @ObservedObject var live: LiveConversationEngine
  @Environment(\.dismiss) private var dismiss
  @AppStorage(SettingKey.coachEnabled) private var coachEnabled = true
  @AppStorage(SettingKey.pressType) private var pressType = "shortPress"
  @AppStorage(SettingKey.geminiVoice) private var geminiVoice = LiveConversationEngine.defaultVoice
  @AppStorage(VoiceLanguage.settingKey) private var voiceLanguage = VoiceLanguage.automatic
  @State private var apiKey = Keychain.geminiKey ?? ""

  var body: some View {
    NavigationStack {
      Form {
        Section {
          SecureField(text: $apiKey) { Text(verbatim: "AIza…") }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          Picker("Voice", selection: $geminiVoice) {
            ForEach(LiveConversationEngine.voices, id: \.self) { Text(verbatim: $0).tag($0) }
          }
          Picker("Voice language", selection: $voiceLanguage) {
            Text("Automatic (iPhone)").tag(VoiceLanguage.automatic)
            ForEach(VoiceLanguage.allCases) { Text(verbatim: $0.displayName).tag($0.rawValue) }
          }
        } header: {
          Text(verbatim: "Gemini")
        } footer: {
          Text("Your Gemini API key from aistudio.google.com, kept in this iPhone's keychain. Changes apply the next time GENIO starts.")
        }

        Section {
          Toggle("Vision coach", isOn: $coachEnabled)
        } footer: {
          Text("A second Gemini model checks the camera every few seconds to confirm steps and spot mistakes. Off: fewer calls, only the conversation checks. Genio is not a safety device.")
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
            Text("Test audio and camera")
          }
          .disabled(genio.active)
        } header: {
          Text("Glasses")
        } footer: {
          Text("If a short press also takes a photo, pick double or long press.")
        }

        Section {
          NavigationLink {
            LogView(genio: genio, live: live)
          } label: {
            LabeledContent("Log") {
              Text("\(genio.log.count) lines")
            }
          }
        } footer: {
          Link(destination: URL(string: "https://github.com/DavideWasTaken/Genio")!) {
            Text(verbatim: "Genio \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · GitHub")
          }
          .font(.footnote)
        }
      }
      .navigationTitle("Settings")
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
          (glasses.status == .connected ? Text("No frame yet.") : Text("Connect the glasses first."))
            .foregroundStyle(.secondary)
        }
        Button("Take a frame") { frame = glasses.latestImage() }
          .disabled(!glasses.cameraActive)
      } header: {
        Text("Camera")
      } footer: {
        Text("The camera runs only while GENIO is on or this page is open, to save the glasses' battery.")
      }
    }
    .navigationTitle("Test audio and camera")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { glasses.setCamera(needed: true, by: "test") }
    .onDisappear {
      stopAudio()
      glasses.setCamera(needed: false, by: "test")
    }
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

/// What Genio heard, said and ran into, newest first, with the live
/// session's numbers on top. "Copy" puts it all on the clipboard, ready to
/// paste into a bug report.
struct LogView: View {
  @ObservedObject var genio: GenioController
  @ObservedObject var live: LiveConversationEngine

  var body: some View {
    List {
      if genio.active {
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
        }
      }
      Section {
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
}
