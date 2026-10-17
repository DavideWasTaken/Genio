import SwiftUI

struct ContentView: View {
  @ObservedObject var genio: GenioController
  @ObservedObject var glasses: Glasses
  @State private var showSettings = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 20) {
          GenioOrb(active: genio.active, thinking: genio.thinking) { genio.toggle() }
            .padding(.top, 4)

          Group {
            if genio.active {
              Text("Say \"done\", \"repeat\", \"back\" or \"new task\". Start a question with \"Genio\".")
            } else {
              Text("Press the button on your glasses or tap here. For a quick question say \"Genio, …\".")
            }
          }
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 12)

          GlassesCard(glasses: glasses)

          if let task = genio.task {
            TaskCard(task: task)
          }

          if !genio.heard.isEmpty {
            Card {
              Label("Heard", systemImage: "waveform")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
              Text(verbatim: "“\(genio.heard)”")
            }
          }
        }
        .padding(20)
      }
      .background(Color(.systemGroupedBackground).ignoresSafeArea())
      .navigationTitle(Text(verbatim: "Genio"))
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            showSettings = true
          } label: {
            Image(systemName: "gearshape")
          }
          .accessibilityLabel(Text("Settings"))
        }
      }
      .sheet(isPresented: $showSettings) {
        SettingsView(genio: genio, glasses: glasses)
      }
    }
    .tint(Color.genioViolet)
  }
}

/// The big round GENIO switch: night violet while asleep, gold while awake.
struct GenioOrb: View {
  let active: Bool
  let thinking: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      ZStack {
        Circle()
          .fill(
            LinearGradient(
              colors: active ? [Color.genioGold, Color.orange] : [Color.genioViolet, Color.genioNight],
              startPoint: .topLeading,
              endPoint: .bottomTrailing))
          .frame(width: 184, height: 184)
          .shadow(color: (active ? Color.genioGold : Color.genioViolet).opacity(0.45), radius: active ? 28 : 14, y: 6)
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
          (active ? Text("on") : Text("paused"))
            .font(.caption.weight(.medium))
            .opacity(0.8)
        }
        .foregroundStyle(active ? Color.genioNight : Color.white)
      }
    }
    .buttonStyle(.plain)
    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: active)
    .sensoryFeedback(.impact(weight: .medium), trigger: active)
    .accessibilityLabel(active ? Text("GENIO is on. Tap to stop") : Text("Start GENIO"))
  }
}

struct GlassesCard: View {
  @ObservedObject var glasses: Glasses

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
        StatusPill(title: "Camera", systemImage: "camera.fill", isOn: glasses.status == .streaming)
        StatusPill(title: "Button", systemImage: "button.programmable", isOn: glasses.buttonReady)
        StatusPill(title: "Voice", systemImage: "waveform", isOn: glasses.speechReady)
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
        if glasses.status == .streaming && !glasses.speechReady {
          action("Turn on voice commands", prominent: false) { await glasses.enableVoice() }
        }
        if glasses.status == .streaming || glasses.status == .waitingForGlasses || glasses.status == .connecting {
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
    case .streaming: return String(localized: "Connected")
    case .failed(let why): return why
    }
  }

  private var statusColor: Color {
    switch glasses.status {
    case .streaming: return .green
    case .failed: return .red
    case .connecting, .waitingForGlasses: return .orange
    case .disconnected: return .secondary
    }
  }
}

struct TaskCard: View {
  let task: GenioTask

  var body: some View {
    Card {
      VStack(alignment: .leading, spacing: 6) {
        Text(verbatim: task.goal)
          .font(.headline)
        (task.finished ? Text("Done") : Text("Step \(task.current + 1) of \(task.steps.count)"))
          .font(.subheadline)
          .foregroundStyle(.secondary)
        ProgressView(value: Double(min(task.current, task.steps.count)), total: Double(max(task.steps.count, 1)))
          .tint(Color.genioGold)
      }
      VStack(alignment: .leading, spacing: 10) {
        ForEach(Array(task.steps.enumerated()), id: \.offset) { index, step in
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon(for: index))
              .foregroundStyle(index < task.current ? Color.green : (index == task.current ? Color.genioViolet : Color.secondary))
            Text(verbatim: step)
              .font(index == task.current ? .body.weight(.semibold) : .body)
              .foregroundStyle(index <= task.current ? Color.primary : Color.secondary)
          }
        }
      }
    }
  }

  private func icon(for index: Int) -> String {
    if index < task.current { return "checkmark.circle.fill" }
    if index == task.current { return "arrow.right.circle.fill" }
    return "circle"
  }
}
