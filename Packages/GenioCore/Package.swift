// swift-tools-version: 6.0
// Genio's platform-independent core: the task engine (plans, steps, completion
// checks, memory), the Gemini Live protocol and session, and media pacing.
// No UIKit, no Meta SDK: it builds and tests on macOS with `swift test`.
import PackageDescription

let package = Package(
  name: "GenioCore",
  defaultLocalization: "en",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [
    .library(name: "GenioCore", targets: ["GenioCore"])
  ],
  targets: [
    .target(name: "GenioCore"),
    .testTarget(name: "GenioCoreTests", dependencies: ["GenioCore"]),
  ],
  swiftLanguageModes: [.v5]
)
