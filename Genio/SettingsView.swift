import SwiftUI
import UIKit

struct SettingsView: View {
  @ObservedObject var genio: GenioController
  @ObservedObject var glasses: Glasses
  @Environment(\.dismiss) private var dismiss
  @State private var apiKey = Keychain.apiKey ?? ""
  @AppStorage(SettingKey.smartModel) private var smartModel = "claude-opus-5-5"
  @AppStorage(SettingKey.coachInterval) private var coachInterval = 6.0
  @AppStorage(SettingKey.pressType) private var pressType = "shortPress"
  @AppStorage(SettingKey.audioRoute) private var audioRoute = Voice.Route.media.rawValue
  @AppStorage(SettingKey.provider) private var provider = "claude"
  @AppStorage(SettingKey.chatgptSmartModel) private var chatgptSmartModel = ""
  @AppStorage(SettingKey.chatgptCoachModel) private var chatgptCoachModel = ""
  @AppStorage(VoiceLanguage.settingKey) private var voiceLanguage = VoiceLanguage.automatic
  @State private var chatgptSignedIn = false
  @State private var chatgptEmail: String?
  @State private var chatgptModels: [ChatGPTBrain.Model] = []
  @State private var chatgptBusy = false
  @State private var chatgptError: String?

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Picker("Brain", selection: $provider) {
            Text(verbatim: "Claude").tag("claude")
            Text("ChatGPT (plan)").tag("chatgpt")
          }
          .pickerStyle(.segmented)
        } header: {
          Text("Brain")
        } footer: {
          if provider == "chatgpt" {
            Text("Uses your ChatGPT Plus/Pro plan instead of API credit. If a Claude key is set too, Claude takes over when the plan hits its limit.")
          } else {
            Text("Claude with an API key: pay as you go, a few cents an hour.")
          }
        }

        if provider == "chatgpt" {
          chatgptSection
        }

        Section {
          SecureField(text: $apiKey) { Text(verbatim: "sk-ant-…") }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          Picker("Questions and plans", selection: $smartModel) {
            Text(verbatim: "Claude Opus 5.5").tag("claude-opus-5-5")
            Text(verbatim: "Claude Sonnet 5.5").tag("claude-sonnet-5-5")
            Text(verbatim: "Claude Haiku 5.5").tag("claude-haiku-5-5")
          }
        } header: {
          Text(verbatim: "Claude")
        } footer: {
          Text("Key from console.anthropic.com; it stays in this iPhone's keychain. The coach uses Claude Haiku 5.5. With ChatGPT the key is optional and acts as a backup.")
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
      }
      .navigationTitle("Settings")
      .task { await refreshChatGPT() }
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            Keychain.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            dismiss()
          }
        }
      }
    }
    .tint(Color.genioViolet)
  }

  private var chatgptSection: some View {
    Section {
      if chatgptSignedIn {
        LabeledContent("Account") {
          Text(verbatim: chatgptEmail ?? "ChatGPT")
        }
        Picker("Coach", selection: $chatgptCoachModel) {
          Text("Automatic").tag("")
          ForEach(chatgptModels) { Text(verbatim: $0.name).tag($0.slug) }
        }
        Picker("Questions and plans", selection: $chatgptSmartModel) {
          Text("Automatic").tag("")
          ForEach(chatgptModels) { Text(verbatim: $0.name).tag($0.slug) }
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
      Text(verbatim: "ChatGPT")
    } footer: {
      Text("Plus has a usage limit every 5 hours, shared with the other apps using your plan; Pro does not. Pick a fast model for the coach.")
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
