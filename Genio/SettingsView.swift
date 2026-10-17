import SwiftUI
import UIKit

/// General settings. The model and the accounts (Claude key, ChatGPT plan)
/// live on their own page, behind the first row.
struct SettingsView: View {
  @ObservedObject var genio: GenioController
  @ObservedObject var glasses: Glasses
  @Environment(\.dismiss) private var dismiss
  @AppStorage(SettingKey.coachInterval) private var coachInterval = 6.0
  @AppStorage(SettingKey.pressType) private var pressType = "shortPress"
  @AppStorage(SettingKey.audioRoute) private var audioRoute = Voice.Route.media.rawValue
  @AppStorage(SettingKey.provider) private var provider = "claude"
  @AppStorage(VoiceLanguage.settingKey) private var voiceLanguage = VoiceLanguage.automatic
  @State private var chatgptEmail: String?
  @State private var chatgptSignedIn = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          NavigationLink {
            BrainSettingsView()
          } label: {
            HStack(spacing: 14) {
              Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(Color.genioGold)
                .frame(width: 34, height: 34)
                .background(Color.genioNight, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
              VStack(alignment: .leading, spacing: 2) {
                Text("Model and accounts")
                Text(verbatim: brainSummary)
                  .font(.footnote)
                  .foregroundStyle(brainReady ? Color.secondary : Color.orange)
              }
            }
            .padding(.vertical, 2)
          }
        }

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
          Text("The voice language is what Genio speaks, understands (\"done\", \"repeat\"…) and answers in. The app's screens follow the iPhone's language; to change them for Genio only, open App language.")
        }

        Section {
          Stepper("Looks every \(Int(coachInterval)) s", value: $coachInterval, in: 3...30, step: 1)
          Picker("Start/stop button", selection: $pressType) {
            Text("Short press").tag("shortPress")
            Text("Double press").tag("doublePress")
            Text("Long press").tag("hold")
          }
          Picker("Audio", selection: $audioRoute) {
            ForEach(Voice.Route.allCases) { Text($0.label).tag($0.rawValue) }
          }
        } header: {
          Text("Coach and glasses")
        } footer: {
          Text("The more often the coach looks, the quicker it reacts and the more it uses. If Genio's voice comes out of the phone instead of the glasses, try the \"Call\" audio.")
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
      // Also runs when coming back from the model page, so the summary
      // reflects a sign-in or a key entered there.
      .onAppear { Task { await refreshSummary() } }
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .tint(Color.genioViolet)
  }

  private var brainReady: Bool {
    provider == "chatgpt" ? chatgptSignedIn : !(Keychain.apiKey ?? "").isEmpty
  }

  private var brainSummary: String {
    if provider == "chatgpt" {
      return chatgptSignedIn
        ? "ChatGPT · " + (chatgptEmail ?? String(localized: "signed in"))
        : "ChatGPT · " + String(localized: "not signed in")
    }
    return (Keychain.apiKey ?? "").isEmpty
      ? "Claude · " + String(localized: "API key missing")
      : "Claude · " + String(localized: "API key set")
  }

  private func refreshSummary() async {
    chatgptSignedIn = await ChatGPTAuth.shared.isSignedIn
    chatgptEmail = await ChatGPTAuth.shared.email
  }
}

/// Which model answers, and the accounts behind it: the Claude API key, or
/// the ChatGPT plan with Claude as an optional backup.
struct BrainSettingsView: View {
  @State private var apiKey = Keychain.apiKey ?? ""
  @AppStorage(SettingKey.provider) private var provider = "claude"
  @AppStorage(SettingKey.smartModel) private var smartModel = "claude-opus-5-5"
  @AppStorage(SettingKey.chatgptSmartModel) private var chatgptSmartModel = ""
  @AppStorage(SettingKey.chatgptCoachModel) private var chatgptCoachModel = ""
  @AppStorage(SettingKey.useBackup) private var useBackup = true
  @State private var chatgptSignedIn = false
  @State private var chatgptEmail: String?
  @State private var chatgptModels: [ChatGPTBrain.Model] = []
  @State private var chatgptBusy = false
  @State private var chatgptError: String?

  var body: some View {
    Form {
      Section {
        Picker("Main", selection: $provider) {
          Text(verbatim: "Claude").tag("claude")
          Text("ChatGPT (plan)").tag("chatgpt")
        }
        .pickerStyle(.segmented)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
      } header: {
        Text("Main")
      } footer: {
        if provider == "chatgpt" {
          Text("Uses your ChatGPT Plus/Pro plan instead of API credit.")
        } else {
          Text("Claude with an API key: pay as you go, a few cents an hour.")
        }
      }

      Section {
        Toggle("Use the other as backup", isOn: $useBackup)
      } footer: {
        Text("If the main one can't answer (credit or plan limit used up, sign-in expired, service down), Genio asks the other one, when it is set up below.")
      }

      if provider == "chatgpt" {
        chatgptSections
        claudeSections
      } else {
        claudeSections
        chatgptSections
      }
    }
    .navigationTitle("Model and accounts")
    .navigationBarTitleDisplayMode(.inline)
    .task { await refreshChatGPT() }
    .onChange(of: apiKey) { _, newValue in
      Keychain.apiKey = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  @ViewBuilder
  private var claudeSections: some View {
    Section {
      claudeKeyField
      Picker("Questions and plans", selection: $smartModel) {
        Text(verbatim: "Claude Opus 5.5").tag("claude-opus-5-5")
        Text(verbatim: "Claude Sonnet 5.5").tag("claude-sonnet-5-5")
        Text(verbatim: "Claude Haiku 5.5").tag("claude-haiku-5-5")
      }
      LabeledContent("Coach") {
        Text(verbatim: "Claude Haiku 5.5")
      }
    } header: {
      Text("Claude (API key)")
    } footer: {
      Text("From console.anthropic.com. It stays in this iPhone's keychain.")
    }
  }

  @ViewBuilder
  private var chatgptSections: some View {
    chatgptAccount
    if chatgptSignedIn {
      Section {
        Picker("Coach", selection: $chatgptCoachModel) {
          Text("Automatic").tag("")
          ForEach(chatgptModels) { Text(verbatim: $0.name).tag($0.slug) }
        }
        Picker("Questions and plans", selection: $chatgptSmartModel) {
          Text("Automatic").tag("")
          ForEach(chatgptModels) { Text(verbatim: $0.name).tag($0.slug) }
        }
      } header: {
        Text("ChatGPT models")
      } footer: {
        Text("Pick a fast model for the coach: it looks every few seconds.")
      }
    }
  }

  private var claudeKeyField: some View {
    SecureField(text: $apiKey) { Text(verbatim: "sk-ant-…") }
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
  }

  private var chatgptAccount: some View {
    Section {
      if chatgptSignedIn {
        LabeledContent("Account") {
          Text(verbatim: chatgptEmail ?? "ChatGPT")
        }
        Button("Sign out of ChatGPT", role: .destructive) {
          Task {
            await ChatGPTAuth.shared.signOut()
            await refreshChatGPT()
          }
        }
      } else {
        Button {
          Task { await signInChatGPT() }
        } label: {
          HStack {
            Text("Sign in with ChatGPT")
            Spacer()
            if chatgptBusy { ProgressView() }
          }
        }
        .disabled(chatgptBusy)
      }
      if let chatgptError {
        Text(verbatim: chatgptError)
          .font(.footnote)
          .foregroundStyle(Color.red)
      }
    } header: {
      Text("ChatGPT (plan)")
    } footer: {
      Text("Plus has a usage limit every 5 hours, shared with the other apps using your plan; Pro does not.")
    }
  }

  private func refreshChatGPT() async {
    chatgptSignedIn = await ChatGPTAuth.shared.isSignedIn
    chatgptEmail = await ChatGPTAuth.shared.email
    guard chatgptSignedIn else {
      chatgptModels = []
      return
    }
    do {
      chatgptModels = try await ChatGPTBrain.models()
    } catch {
      chatgptError = String(localized: "Models unavailable: \(error.localizedDescription)")
    }
  }

  private func signInChatGPT() async {
    chatgptBusy = true
    chatgptError = nil
    do {
      try await ChatGPTAuth.shared.signIn()
    } catch {
      chatgptError = error.localizedDescription
    }
    chatgptBusy = false
    await refreshChatGPT()
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
