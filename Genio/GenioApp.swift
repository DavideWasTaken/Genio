import MWDATCore
import SwiftUI

@main
struct GenioApp: App {
  @StateObject private var genio = GenioController()

  init() {
    do {
      try Wearables.configure()
    } catch {
      NSLog("[Genio] Wearables.configure failed: %@", String(describing: error))
    }
  }

  var body: some Scene {
    WindowGroup {
      ContentView(genio: genio, glasses: genio.glasses)
        // Meta AI calls back here after registration and permission grants.
        // Only its own links go to the SDK.
        .onOpenURL { url in
          guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
          else { return }
          Task {
            do {
              _ = try await Wearables.shared.handleUrl(url)
            } catch {
              NSLog("[Genio] handleUrl failed: %@", String(describing: error))
            }
          }
        }
    }
  }
}
