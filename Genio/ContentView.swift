import GenioCore
import SwiftUI

struct ContentView: View {
  @ObservedObject var genio: GenioController
  @ObservedObject var glasses: GlassesManager
  @ObservedObject var live: LiveConversationEngine
  @State private var showSettings = false

  private var glassesReady: Bool { glasses.status == .connected }

  private var connecting: Bool {
    switch live.status {
    case .connecting, .reconnecting: return true
    default: return false
    }
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 20) {
          // Title and settings on one line, centred on each other.
          HStack(alignment: .center) {
            Text(verbatim: "Genio")
              .font(.largeTitle.bold())
            Spacer()
            Button {
              showSettings = true
            } label: {
              Image(systemName: "gearshape")
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(Color(.secondarySystemGroupedBackground), in: Circle())
            }
            .accessibilityLabel(Text("Settings"))
          }

          GenioOrb(active: genio.active, thinking: connecting, available: glassesReady || genio.active) {
            genio.toggle()
          }
          .padding(.top, 4)

          Group {
            if genio.active, case .reconnecting = live.status {
              Text("Connection lost: reconnecting to Gemini. The task is safe.")
            } else if genio.active, live.status == .connecting {
              Text("Connecting to Gemini…")
            } else if genio.active {
              Text("Genio is listening. Say \"Genio stop\" to switch off.")
            } else if !glassesReady {
              Text("Connect the glasses first: GENIO needs their camera, button and microphone.")
            } else if (Keychain.geminiKey ?? "").isEmpty {
              Text("Add your Gemini API key in Settings, then press the button on your glasses.")
            } else {
              Text("Press the button on your glasses or tap here.")
            }
          }
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 12)

          GlassesCard(glasses: glasses, audio: genio.audio, liveActive: genio.active)

          if let task = genio.task {
            TaskCard(task: task, paused: genio.taskEngine.paused && !genio.active)
          }

        }
        .padding(20)
      }
      .background(Color(.systemGroupedBackground).ignoresSafeArea())
      .toolbar(.hidden, for: .navigationBar)
      // Glasses gone while GENIO is on (folded, out of range): stop it. The
      // task stays saved and resumes with the next press.
      .onChange(of: glasses.status) { _, status in
        if status != .connected && genio.active { genio.stop() }
      }
      .sheet(isPresented: $showSettings) {
        SettingsView(genio: genio, glasses: glasses, live: live)
      }
    }
    .tint(Color.genioViolet)
  }
}

/// The big round GENIO switch: night violet while asleep, gold while awake.
struct GenioOrb: View {
  let active: Bool
  let thinking: Bool
  /// False while the glasses are not connected: the orb is greyed out and
  /// does nothing.
  let available: Bool
  let action: () -> Void

  private var colors: [Color] {
    if active { return [Color.genioGold, Color.orange] }
    if available { return [Color.genioViolet, Color.genioNight] }
    return [Color(.systemGray3), Color(.systemGray5)]
  }

  var body: some View {
    Button(action: action) {
      ZStack {
        Circle()
          .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
          .frame(width: 184, height: 184)
          .shadow(
            color: (active ? Color.genioGold : Color.genioViolet).opacity(available ? 0.45 : 0),
            radius: active ? 28 : 14, y: 6)
        VStack(spacing: 6) {
          if thinking {
            ProgressView()
              .controlSize(.large)
              .tint(active ? Color.genioNight : Color.white)
          } else {
            Image(systemName: active ? "sparkles" : "eyeglasses")
              .font(.system(size: 44, weight: .semibold))
              .symbolEffect(.pulse, options: .repeating, isActive: active)
          }
          Text(verbatim: "GENIO")
            .font(.system(size: 22, weight: .heavy, design: .rounded))
            .tracking(3)
          (active ? Text("on") : (available ? Text("paused") : Text("glasses not connected")))
            .font(.caption.weight(.medium))
            .opacity(0.8)
        }
        .foregroundStyle(active ? Color.genioNight : (available ? Color.white : Color.secondary))
      }
    }
    .buttonStyle(.plain)
    .disabled(!available)
    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: active)
    .animation(.easeInOut(duration: 0.2), value: available)
    .sensoryFeedback(.impact(weight: .medium), trigger: active)
    .accessibilityLabel(
      active ? Text("GENIO is on. Tap to stop")
        : (available ? Text("Start GENIO") : Text("GENIO: connect the glasses first")))
  }
}

struct GlassesCard: View {
  @ObservedObject var glasses: GlassesManager
  @ObservedObject var audio: AudioManager
  /// GENIO is on: the microphone pill shows the real route.
  let liveActive: Bool

  var body: some View {
    Card {
      HStack(alignment: .firstTextBaseline) {
        Label("Glasses", systemImage: "eyeglasses")
          .font(.headline)
        Spacer()
        Text(statusText)
          .font(.subheadline)
          .foregroundStyle(statusColor)
          .multilineTextAlignment(.trailing)
      }

      HStack(spacing: 8) {
        StatusPill(title: "Camera", systemImage: "camera.fill", isOn: glasses.cameraActive)
        StatusPill(title: "Button", systemImage: "button.programmable", isOn: glasses.buttonReady)
        StatusPill(title: "Microphone", systemImage: "mic.fill", isOn: liveActive && audio.micIsGlasses)
      }
      if liveActive, !audio.micIsGlasses, audio.mode == .live {
        Text("Gemini is hearing the phone's microphone, not the glasses: \(audio.route.input)")
          .font(.footnote)
          .foregroundStyle(Color.orange)
      }

      ForEach(glasses.deviceLines, id: \.self) { line in
        Text(line)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      VStack(spacing: 10) {
        if !glasses.registered {
          action("Link with Meta AI", prominent: true) { await glasses.register() }
        } else if glasses.status == .disconnected || isFailed {
          action("Connect glasses", prominent: true) { await glasses.connect() }
        }
        if glasses.needsGlassesAppUpdate {
          action("Update the glasses software", prominent: false) { await glasses.openGlassesAppUpdate() }
        }
        if glasses.status == .connected || glasses.status == .waitingForGlasses || glasses.status == .connecting {
          Button("Disconnect", role: .destructive) { glasses.disconnect() }
            .font(.subheadline)
        }
      }
    }
  }

  @ViewBuilder
  private func action(_ title: LocalizedStringKey, prominent: Bool, run: @escaping () async -> Void) -> some View {
    if prominent {
      Button(title) { Task { await run() } }
        .buttonStyle(.borderedProminent)
        .frame(maxWidth: .infinity)
    } else {
      Button(title) { Task { await run() } }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
    }
  }

  private var isFailed: Bool {
    if case .failed = glasses.status { return true }
    return false
  }

  private var statusText: String {
    switch glasses.status {
    case .disconnected:
      return glasses.registered ? String(localized: "Not connected") : String(localized: "Link with Meta AI first")
    case .connecting: return String(localized: "Connecting…")
    case .waitingForGlasses: return String(localized: "Waiting for the glasses")
    case .connected: return String(localized: "Connected")
    case .failed(let why): return why
    }
  }

  private var statusColor: Color {
    switch glasses.status {
    case .connected: return .green
    case .failed: return .red
    case .connecting, .waitingForGlasses: return .orange
    case .disconnected: return .secondary
    }
  }
}

struct TaskCard: View {
  let task: GenioTask
  /// Saved and waiting for GENIO to resume it.
  var paused = false

  var body: some View {
    Card {
      VStack(alignment: .leading, spacing: 6) {
        Text(verbatim: task.goal)
          .font(.headline)
        Group {
          if task.finished {
            Text("Done")
          } else if paused {
            Text("Step \(task.current + 1) of \(task.steps.count) · paused, press to resume")
          } else {
            Text("Step \(task.current + 1) of \(task.steps.count)")
          }
        }
          .font(.subheadline)
          .foregroundStyle(.secondary)
        ProgressView(value: Double(min(task.current, task.steps.count)), total: Double(max(task.steps.count, 1)))
          .tint(Color.genioGold)
        // Only the step at hand: the rest is Genio's job.
        if let step = task.currentStep {
          Text(verbatim: step)
            .font(.body.weight(.semibold))
            .padding(.top, 2)
        }
      }
    }
  }
}
