import Foundation
import MWDATCamera
import MWDATCore
import MWDATInputs
import UIKit

/// Everything that talks to the glasses through Meta's DAT SDK (1.0):
/// registration with Meta AI, the device session, the camera stream (only the
/// latest frame is kept, for Gemini to look at) and the capture button
/// (Inputs). Listening is not done here: Gemini Live hears the user through
/// the glasses' Bluetooth microphone (AudioManager), so the glasses' own
/// speech recognition (DAT Speech) is not used and nothing is heard twice.
///
/// Inputs is experimental in DAT 1.0: it works for development and beta
/// builds, not for App Store release yet.
@MainActor
final class GlassesManager: ObservableObject {
  enum Status: Equatable {
    case disconnected
    case connecting
    case waitingForGlasses
    case streaming
    case failed(String)
  }

  @Published private(set) var registered = false
  @Published private(set) var status: Status = .disconnected
  /// The capture button is wired up (Inputs attached).
  @Published private(set) var buttonReady = false
  /// One line per pair Meta AI knows: name, link, compatibility, worn, battery.
  @Published private(set) var deviceLines: [String] = []
  /// The glasses refused the session because their DAT app is too old for
  /// this SDK: the UI offers the update.
  @Published private(set) var needsGlassesAppUpdate = false

  /// A press of the capture button.
  var onPress: ((CapturePressType) -> Void)?
  /// Diagnostic lines for the in-app log (errors, permission answers).
  var onLog: ((String) -> Void)?

  private var session: DeviceSession?
  private var camera: Camera?
  private var inputs: Inputs?
  private var tokens = ListenerTokenBag()
  private var sessionTasks: [Task<Void, Never>] = []
  private var registrationTask: Task<Void, Never>?
  private var devicesTask: Task<Void, Never>?
  private var deviceTokens: [any AnyListenerToken] = []
  /// Camera restarts after a stream error, capped so a camera that keeps
  /// failing does not loop forever; reset once it has run for a minute.
  private var cameraRestarts = 0
  private var cameraRestarting = false
  private var streamingSince: Date?
  /// True while the started session is asking for permissions, so a second
  /// `.started` cannot start a second round of requests.
  private var preparing = false
  private let latest = LatestFrame()

  private enum Access: Equatable {
    case granted
    case denied
    case unreadable(String)
  }

  // MARK: - Registration (once, through the Meta AI app)

  /// Keeps `deviceLines` current: the pairs Meta AI knows and their state.
  func observeDevices() {
    guard devicesTask == nil else { return }
    devicesTask = Task { [weak self] in
      for await identifiers in Wearables.shared.devicesStream() {
        guard let self else { return }
        for token in self.deviceTokens { await token.cancel() }
        self.deviceTokens.removeAll()
        let devices = identifiers.compactMap { Wearables.shared.deviceForIdentifier($0) }
        self.describe(devices)
        // Device properties fill in asynchronously: re-read on every change.
        for device in devices {
          let refresh: @Sendable (Any) -> Void = { [weak self] _ in
            Task { @MainActor in self?.describe(devices) }
          }
          self.deviceTokens.append(device.addLinkStateListener(refresh))
          self.deviceTokens.append(device.addCompatibilityListener(refresh))
          self.deviceTokens.append(device.addDeviceStateListener(refresh))
        }
      }
    }
  }

  private func describe(_ devices: [Device]) {
    deviceLines = devices.map { device in
      let name = device.name.isEmpty ? String(localized: "Meta glasses") : device.name
      let link = device.linkState == .connected
        ? String(localized: "connected")
        : String(localized: "not connected (\(String(describing: device.linkState)))")
      let compatibility = device.compatibility() == .compatible ? "" : " · \(device.compatibility())"
      let worn = device.donState == .donned ? " · " + String(localized: "worn") : ""
      let battery = device.batteryLevel.flatMap { $0 > 0 ? " · \($0)%" : nil } ?? ""
      return "\(name): \(link)\(compatibility)\(worn)\(battery)"
    }
  }

  /// The pair to open a session on: connected and worn first, then connected.
  private func preferredDevice() -> Device? {
    let devices = Wearables.shared.devices.compactMap { Wearables.shared.deviceForIdentifier($0) }
    let connected = devices.filter { $0.linkState == .connected }
    return connected.first { $0.donState == .donned } ?? connected.first
  }

  func observeRegistration() {
    observeDevices()
    guard registrationTask == nil else { return }
    registrationTask = Task { [weak self] in
      for await state in Wearables.shared.registrationStateStream() {
        if case .registered = state {
          self?.registered = true
        } else {
          self?.registered = false
        }
      }
    }
  }

  func register() async {
    do {
      try await Wearables.shared.startRegistration()
    } catch {
      status = .failed(String(localized: "Linking failed: \(error.localizedDescription)"))
    }
  }

  // MARK: - Session

  /// Opens Meta AI on the page that updates the DAT app on the glasses.
  func openGlassesAppUpdate() async {
    do {
      try await Wearables.shared.openDATGlassesAppUpdate()
    } catch {
      log("Could not open the update: \(error)")
    }
  }

  func connect() async {
    guard session == nil else { return }
    status = .connecting
    needsGlassesAppUpdate = false

    // Wait up to 20 s for a pair to be connected: after opening the glasses
    // or the app, the link takes a few seconds to come up.
    var device = preferredDevice()
    if device == nil {
      status = .waitingForGlasses
      log("Waiting for the glasses to connect…")
      for _ in 0..<20 where device == nil {
        try? await Task.sleep(for: .seconds(1))
        device = preferredDevice()
      }
    }
    guard let device else {
      status = .failed(noDeviceReason())
      return
    }
    if device.compatibility() == .deviceUpdateRequired {
      status = .failed(String(localized: "The glasses need an update: Meta AI → your glasses → updates."))
      try? await Wearables.shared.openFirmwareUpdate()
      return
    }

    do {
      let wearables = Wearables.shared
      log("Session on \(device.name.isEmpty ? device.identifier : device.name)")
      let newSession = try wearables.createSession(deviceSelector: SpecificDeviceSelector(device: device.identifier))
      session = newSession
      try newSession.start()

      sessionTasks.append(Task { [weak self] in
        for await error in newSession.errorStream() {
          self?.log("Session error: \(error)")
          if error == .datAppOnTheGlassesUpdateRequired {
            self?.needsGlassesAppUpdate = true
            self?.status = .failed(String(localized: "The glasses software needs an update."))
          }
        }
      })
      sessionTasks.append(Task { [weak self] in
        for await state in newSession.stateStream() {
          guard let self else { return }
          switch state {
          case .started:
            // Permissions are read from the glasses themselves, so they can
            // only be checked once the session has started (Meta's samples do
            // the same); before that the check throws instead of answering.
            await self.prepare(newSession)
          case .stopped:
            // Keep a failure on screen: the session stops right after the
            // error that explains why.
            if case .failed = self.status {
              self.teardown(self.status)
            } else {
              self.teardown(.disconnected)
            }
            return
          default:
            break
          }
        }
      })
    } catch {
      session = nil
      status = .failed(String(localized: "Session not started: \(error.localizedDescription)"))
    }
  }

  /// Why no pair could be used, in words the user can act on.
  private func noDeviceReason() -> String {
    let devices = Wearables.shared.devices.compactMap { Wearables.shared.deviceForIdentifier($0) }
    if devices.isEmpty {
      return String(localized: "Meta AI reports no glasses: pair them in the Meta AI app and try again.")
    }
    return String(localized: "Glasses not connected: unfold and wear them, and check that Meta AI shows them connected and Bluetooth is on.")
  }

  func disconnect() {
    session?.stop()
    teardown(.disconnected)
  }

  private func teardown(_ newStatus: Status) {
    for task in sessionTasks { task.cancel() }
    sessionTasks.removeAll()
    let old = tokens
    tokens = ListenerTokenBag()
    Task { await old.cancelAll() }
    session = nil
    camera = nil
    inputs = nil
    buttonReady = false
    cameraRestarts = 0
    cameraRestarting = false
    streamingSince = nil
    latest.clear()
    status = newStatus
  }

  /// Camera permission first (required), then the camera stream. The button
  /// follows the first frame.
  private func prepare(_ session: DeviceSession) async {
    guard camera == nil, !preparing else { return }
    preparing = true
    defer { preparing = false }

    switch await access(.camera) {
    case .granted:
      break
    case .denied:
      status = .failed(String(localized: "Camera permission denied in Meta AI."))
      return
    case .unreadable(let why):
      status = .failed(String(localized: "Camera permission unreadable: \(why)"))
      return
    }
    guard self.session === session else { return }  // disconnected meanwhile
    attachCamera(to: session)
  }

  /// Checks a grant, and asks for it through Meta AI if it is missing. A
  /// thrown error is not a denial: it usually means the glasses are not
  /// reachable yet, so it is reported as such.
  private func access(_ permission: MWDATCore.Permission) async -> Access {
    do {
      if try await Wearables.shared.checkPermissionStatus(permission) == .granted {
        log("Permission \(permission): granted")
        return .granted
      }
      log("Permission \(permission): asking in Meta AI")
      let answer = try await Wearables.shared.requestPermission(permission)
      log("Permission \(permission): \(answer == .granted ? "granted" : "denied")")
      return answer == .granted ? .granted : .denied
    } catch {
      log("Permission \(permission) unreadable: \(error)")
      return .unreadable(error.localizedDescription)
    }
  }

  /// To the in-app Log (which also prints to the Xcode console).
  private func log(_ line: String) {
    onLog?(line)
  }

  // MARK: - Camera

  private func attachCamera(to session: DeviceSession) {
    guard camera == nil else { return }
    // Medium (504x896) at 7 fps: plenty for Gemini (which gets at most one
    // frame a second), gentle on Bluetooth.
    let config = StreamConfiguration(videoCodec: .raw, resolution: .medium, frameRate: 7)
    do {
      guard let newCamera = try session.addCamera(config: config) else {
        status = .failed(String(localized: "The glasses camera is not available."))
        return
      }
      camera = newCamera
      let latest = self.latest
      newCamera.stream.videoFramePublisher.listen { [weak self] frame in
        if latest.set(frame) {
          Task { @MainActor in self?.attachButton(to: session) }
        }
      }.store(in: tokens)
      newCamera.stream.statePublisher.listen { [weak self] state in
        Task { @MainActor in
          // Events from a camera already replaced by a restart are stale.
          guard let self, self.camera === newCamera else { return }
          switch state {
          case .streaming:
            self.status = .streaming
            self.streamingSince = Date()
          case .waitingForDevice, .starting:
            self.status = .waitingForGlasses
          case .stopped where self.streamingSince != nil:
            // Only a stream that was running: not one still starting up.
            self.restartCamera(on: session, reason: "stream stopped")
          default:
            break
          }
        }
      }.store(in: tokens)
      newCamera.stream.errorPublisher.listen { [weak self] error in
        Task { @MainActor in
          guard let self, self.camera === newCamera else { return }
          self.log("Camera error: \(error)")
          self.restartCamera(on: session, reason: "\(error)")
        }
      }.store(in: tokens)
      newCamera.stream.start()
    } catch {
      status = .failed(String(localized: "Camera: \(error.localizedDescription)"))
    }
  }

  /// Brings the camera stream back after an error (such as
  /// videoStreamingError) or an unexpected stop, so Gemini and the coach
  /// keep seeing. The button stays attached to the session.
  private func restartCamera(on session: DeviceSession, reason: String) {
    guard self.session === session, camera != nil, !cameraRestarting else { return }
    if let since = streamingSince, Date().timeIntervalSince(since) > 60 {
      cameraRestarts = 0
    }
    guard cameraRestarts < 5 else {
      log("Camera: gave up after 5 restarts (\(reason)). Disconnect and connect the glasses again.")
      return
    }
    cameraRestarts += 1
    cameraRestarting = true
    streamingSince = nil
    log("Camera: restarting after \(reason) (\(cameraRestarts)/5)")
    camera?.stop()
    camera = nil
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(2))
      guard let self else { return }
      self.cameraRestarting = false
      guard self.session === session else { return }
      self.attachCamera(to: session)
    }
  }

  /// The most recent frame and its age, for the camera test in Settings.
  func latestImage() -> (UIImage, TimeInterval)? {
    guard let snapshot = latest.get(), let image = snapshot.frame.makeUIImage() else { return nil }
    return (image, Date().timeIntervalSince(snapshot.arrivedAt))
  }

  /// When the newest frame arrived (nil if none), without touching it.
  var latestFrameTime: Date? { latest.get()?.arrivedAt }

  /// The newest frame as a JPEG, encoded off the main thread: (JPEG, when
  /// the frame arrived). `maxDimension` scales it down first (Gemini Live
  /// gains nothing from more pixels than its low media resolution uses).
  func latestJPEGInBackground(maxAge: TimeInterval = 5, maxDimension: CGFloat? = nil, quality: CGFloat = 0.6) async -> (Data, Date)? {
    guard let snapshot = latest.get(), Date().timeIntervalSince(snapshot.arrivedAt) <= maxAge else { return nil }
    let box = FrameBox(frame: snapshot.frame)
    let arrivedAt = snapshot.arrivedAt
    return await Task.detached(priority: .userInitiated) {
      guard let image = box.frame.makeUIImage() else { return nil }
      let scaled = maxDimension.map { Self.scaled(image, maxDimension: $0) } ?? image
      return scaled.jpegData(compressionQuality: quality).map { ($0, arrivedAt) }
    }.value
  }

  nonisolated private static func scaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
    let longest = max(image.size.width, image.size.height)
    guard longest > maxDimension, longest > 0 else { return image }
    let factor = maxDimension / longest
    let size = CGSize(width: (image.size.width * factor).rounded(), height: (image.size.height * factor).rounded())
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: size))
    }
  }

  // MARK: - Button

  private func attachButton(to session: DeviceSession) {
    guard inputs == nil else { return }
    do {
      // Only the capture button; Back stays with the system.
      let configuration = InputsConfiguration(sources: [.captureButton], consumeBack: false)
      guard let newInputs = try session.addInputs(configuration: configuration) else {
        log("These glasses expose no button (Inputs).")
        return
      }
      inputs = newInputs
      buttonReady = true
      sessionTasks.append(Task { [weak self] in
        for await event in newInputs.events {
          if case let .capture(pressType, _, _) = event {
            self?.onPress?(pressType)
          }
        }
      })
      newInputs.errorPublisher.listen { [weak self] error in
        Task { @MainActor in self?.log("Button error: \(error)") }
      }.store(in: tokens)
    } catch {
      log("Button not attached: \(error)")
    }
  }
}

/// Hands a frame to a background task for encoding (the SDK's frames are
/// immutable once delivered).
private struct FrameBox: @unchecked Sendable {
  let frame: VideoFrame
}

/// The newest camera frame and when it arrived. Written from the SDK's
/// thread at every frame, read rarely from the main actor.
final class LatestFrame: @unchecked Sendable {
  private let lock = NSLock()
  private var frame: VideoFrame?
  private var arrivedAt = Date.distantPast

  /// Stores the frame; returns true if it is the first since the last clear.
  func set(_ newFrame: VideoFrame) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let first = frame == nil
    frame = newFrame
    arrivedAt = Date()
    return first
  }

  func get() -> (frame: VideoFrame, arrivedAt: Date)? {
    lock.lock()
    defer { lock.unlock() }
    guard let frame else { return nil }
    return (frame, arrivedAt)
  }

  func clear() {
    lock.lock()
    frame = nil
    lock.unlock()
  }
}
