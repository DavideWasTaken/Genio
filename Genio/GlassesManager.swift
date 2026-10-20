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
    /// The session is up and the camera works; the camera itself streams
    /// only while someone needs it (see `cameraActive`).
    case connected
    case failed(String)
  }

  @Published private(set) var registered = false
  @Published private(set) var status: Status = .disconnected
  /// The capture button is wired up (Inputs attached).
  @Published private(set) var buttonReady = false
  /// The camera is streaming frames right now. It runs only while GENIO is
  /// on or the camera test is open: idle glasses keep just the button, to
  /// save their battery.
  @Published private(set) var cameraActive = false
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
  /// The photo a close look asked for (see closeLookImage).
  private let photoBox = PhotoBox()
  /// Who needs the camera now ("genio", "test"); empty: it is paused.
  private var cameraUsers: Set<String> = []
  /// The current Inputs reached `.active` at least once.
  private var buttonWasActive = false

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
    cameraActive = false
    cameraRestarts = 0
    cameraRestarting = false
    streamingSince = nil
    latest.clear()
    status = newStatus
  }

  /// Camera permission first (required), then a short camera start: the
  /// button is attached after the first frame (proof that the session works),
  /// then the camera pauses until GENIO or the camera test needs it.
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
          Task { @MainActor in
            self?.attachButton(to: session)
            self?.pauseCameraIfUnneeded()
          }
        }
      }.store(in: tokens)
      let photoBox = self.photoBox
      newCamera.stream.photoDataPublisher.listen { photo in
        photoBox.deliver(photo.data)
      }.store(in: tokens)
      newCamera.stream.statePublisher.listen { [weak self] state in
        Task { @MainActor in
          // Events from a camera already replaced by a restart are stale.
          guard let self, self.camera === newCamera else { return }
          self.log("Camera: \(state)")
          switch state {
          case .streaming:
            self.status = .connected
            self.cameraActive = true
            self.streamingSince = Date()
          case .waitingForDevice, .starting:
            // A camera starting again on a working session (GENIO switched
            // on) does not make the glasses less connected.
            if self.status != .connected { self.status = .waitingForGlasses }
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
          if error == .photoCaptureFailed {
            // Only the photo failed: the stream goes on, the close look
            // falls back to the video.
            self.log("Camera: photo failed")
            photoBox.fail()
            return
          }
          self.log("Camera error: \(error)")
          self.restartCamera(on: session, reason: "\(error)")
        }
      }.store(in: tokens)
      newCamera.stream.start()
      watchStart(of: newCamera, on: session)
    } catch {
      status = .failed(String(localized: "Camera: \(error.localizedDescription)"))
    }
  }

  /// A start can hang, or stop before streaming, without an error: the
  /// camera then looks on to `setCamera` and never sends a frame. If someone
  /// needs it and no frame came in time, it is restarted.
  private func watchStart(of newCamera: Camera, on session: DeviceSession) {
    let startedAt = Date()
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.cameraStartTimeout))
      guard let self, self.camera === newCamera, !self.cameraUsers.isEmpty else { return }
      if let frame = self.latestFrameTime, frame >= startedAt { return }
      self.restartCamera(on: session, reason: "no frame after \(Int(Self.cameraStartTimeout)) s")
    }
  }

  private static let cameraStartTimeout: TimeInterval = 7

  /// Brings the camera stream back after an error (such as
  /// videoStreamingError) or an unexpected stop, so Gemini and the coach
  /// keep seeing. The button stays attached to the session.
  private func restartCamera(on session: DeviceSession, reason: String) {
    guard self.session === session, camera != nil, !cameraRestarting else { return }
    guard !cameraUsers.isEmpty || status != .connected else {
      // Nobody needs it: leave it off.
      pauseCamera(reason: reason)
      return
    }
    if let since = streamingSince, Date().timeIntervalSince(since) > 60 {
      cameraRestarts = 0
    }
    guard cameraRestarts < 5 else {
      log("Camera: gave up after 5 restarts (\(reason)). Disconnect and connect the glasses again.")
      // Off, not left half-started: the next request starts it afresh.
      pauseCamera(reason: "gave up")
      cameraRestarts = 0
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
      guard self.session === session, !self.cameraUsers.isEmpty || self.status != .connected else { return }
      self.attachCamera(to: session)
    }
  }

  /// Starts the camera for `user` ("genio", "test") or releases it. It
  /// streams while anyone needs it and pauses when nobody does.
  func setCamera(needed: Bool, by user: String) {
    if needed { cameraUsers.insert(user) } else { cameraUsers.remove(user) }
    guard let session, status == .connected else {
      if needed { log("Camera: wanted by \(user), but the glasses are not connected") }
      return
    }
    if !cameraUsers.isEmpty, camera == nil, !cameraRestarting {
      log("Camera: on (\(cameraUsers.sorted().joined(separator: ", ")))")
      attachCamera(to: session)
    } else if cameraUsers.isEmpty {
      pauseCameraIfUnneeded()
    }
  }

  private func pauseCameraIfUnneeded() {
    guard cameraUsers.isEmpty, camera != nil, inputs != nil else { return }
    // A frame arrived, so the glasses work, even if the camera's own
    // "streaming" event has not come yet (it would be ignored once paused).
    if status != .connected { status = .connected }
    pauseCamera(reason: "not needed")
  }

  /// Stops the stream; the session and the button stay up.
  private func pauseCamera(reason: String) {
    let old = camera
    camera = nil  // first, so its .stopped event is not taken for a failure
    old?.stop()
    streamingSince = nil
    cameraActive = false
    latest.clear()
    log("Camera: off (\(reason))")
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

  // MARK: - Close look

  /// A sharp still for a close look (look_closely), as a JPEG at most
  /// `maxDimension` pixels on its long side: a photo from the glasses (far
  /// more detail than the medium video stream) if it arrives in time, else
  /// the sharpest video frame of the next second or so. Nil if the camera is
  /// not streaming. `source` is "photo" or "frame".
  func closeLookImage(maxDimension: CGFloat = 2048) async -> (data: Data, source: String)? {
    guard let camera, cameraActive else { return nil }
    photoBox.expect()
    let asked = camera.stream.capturePhoto(format: .jpeg)
    log(asked ? "Close look: photo requested" : "Close look: no photo (refused), using the video")
    if !asked { photoBox.fail() }
    // Meanwhile, the user holds still: keep the sharpest frame as a fallback.
    let best = await sharpestFrame(over: 1.2)
    let photo = asked ? await photoBox.wait(until: Date().addingTimeInterval(4)) : nil
    photoBox.reset()
    if let photo {
      let encoded = await Task.detached(priority: .userInitiated) { () -> Data? in
        guard let image = UIImage(data: photo) else { return nil }
        return Self.scaled(image, maxDimension: maxDimension).jpegData(compressionQuality: 0.85)
      }.value
      if let encoded {
        log("Close look: photo \(photo.count / 1024) KB")
        return (data: encoded, source: "photo")
      }
    }
    guard let best else { return nil }
    log("Close look: photo not received, using the sharpest frame")
    let box = FrameBox(frame: best)
    let encoded = await Task.detached(priority: .userInitiated) { () -> Data? in
      box.frame.makeUIImage()?.jpegData(compressionQuality: 0.9)
    }.value
    return encoded.map { (data: $0, source: "frame") }
  }

  /// The sharpest of the frames arriving during `seconds` (the current one
  /// included if it is recent), or nil if none came.
  private func sharpestFrame(over seconds: TimeInterval) async -> VideoFrame? {
    var best: (frame: VideoFrame, score: Double)?
    var lastSeen: Date?
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
      if let snapshot = latest.get(), snapshot.arrivedAt != lastSeen, Date().timeIntervalSince(snapshot.arrivedAt) < 3 {
        lastSeen = snapshot.arrivedAt
        let box = FrameBox(frame: snapshot.frame)
        let score = await Task.detached(priority: .userInitiated) { Self.sharpness(of: box.frame) }.value
        if score > (best?.score ?? -1) { best = (snapshot.frame, score) }
      }
      try? await Task.sleep(for: .milliseconds(60))
    }
    return best?.frame
  }

  /// Sharpness of a frame (see Sharpness), on a small grayscale copy.
  nonisolated private static func sharpness(of frame: VideoFrame) -> Double {
    guard let image = frame.makeUIImage(), let small = scaled(image, maxDimension: 320).cgImage else { return 0 }
    let width = small.width
    let height = small.height
    var pixels = [UInt8](repeating: 0, count: width * height)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard let context = CGContext(
        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
      else { return false }
      context.draw(small, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    return drawn ? Sharpness.score(gray: pixels, width: width, height: height) : 0
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
      buttonWasActive = false
      sessionTasks.append(Task { [weak self] in
        for await event in newInputs.events {
          if case let .capture(pressType, _, _) = event {
            self?.onPress?(pressType)
          } else {
            self?.log("Input: \(event)")
          }
        }
      })
      newInputs.statePublisher.listen { [weak self] state in
        Task { @MainActor in self?.inputsStateChanged(state, inputs: newInputs, session: session) }
      }.store(in: tokens)
      newInputs.errorPublisher.listen { [weak self] error in
        Task { @MainActor in self?.log("Button error: \(error)") }
      }.store(in: tokens)
    } catch {
      log("Button not attached: \(error)")
    }
  }

  /// Logs the button's state and attaches it again if it stops while the
  /// session is still up (presses would then go to the glasses' own photo
  /// and video actions).
  private func inputsStateChanged(_ state: InputsState, inputs current: Inputs, session: DeviceSession) {
    guard inputs === current else { return }
    log("Button: \(state)\(cameraActive ? " (camera on)" : "")")
    if state == .active { buttonWasActive = true }
    buttonReady = state == .active || !buttonWasActive
    // Only an Inputs that had been working: one still starting up passes
    // through .inactive on its own.
    guard state == .inactive, buttonWasActive, self.session === session else { return }
    inputs = nil
    try? session.removeInputs()
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard let self, self.session === session, self.inputs == nil else { return }
      self.log("Button: attaching again")
      self.attachButton(to: session)
    }
  }
}

/// Hands a frame to a background task for encoding (the SDK's frames are
/// immutable once delivered).
private struct FrameBox: @unchecked Sendable {
  let frame: VideoFrame
}

/// The photo a close look is waiting for. Written from the SDK's thread when
/// the photo (or its failure) arrives; a photo nobody asked for (none
/// expected) is ignored.
final class PhotoBox: @unchecked Sendable {
  private let lock = NSLock()
  private var expecting = false
  private var failed = false
  private var data: Data?

  func expect() {
    lock.lock()
    expecting = true
    failed = false
    data = nil
    lock.unlock()
  }

  func deliver(_ photo: Data) {
    lock.lock()
    if expecting, data == nil { data = photo }
    lock.unlock()
  }

  func fail() {
    lock.lock()
    if expecting { failed = true }
    lock.unlock()
  }

  func reset() {
    lock.lock()
    expecting = false
    failed = false
    data = nil
    lock.unlock()
  }

  /// The photo, or nil if it failed or `deadline` passed first.
  func wait(until deadline: Date) async -> Data? {
    while Date() < deadline {
      let (photo, gaveUp) = peek()
      if let photo { return photo }
      if gaveUp { return nil }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return peek().photo
  }

  private func peek() -> (photo: Data?, failed: Bool) {
    lock.lock()
    defer { lock.unlock() }
    return (data, failed)
  }
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
