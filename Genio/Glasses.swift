import Foundation
import MWDATCamera
import MWDATCore
import MWDATInputs
import MWDATSpeech
import UIKit

/// Everything that talks to the glasses through Meta's DAT SDK (1.0):
/// registration with Meta AI, the device session, the camera stream (only the
/// latest frame is kept, for Claude to look at), the capture button (Inputs)
/// and on-glasses speech recognition (Speech).
///
/// Inputs and Speech are experimental in DAT 1.0: they work for development
/// and beta builds, not for App Store release yet.
@MainActor
final class Glasses: ObservableObject {
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
  /// The glasses are transcribing what you say (Speech started).
  @Published private(set) var speechReady = false
  /// One line per pair Meta AI knows: name, link, compatibility, worn, battery.
  @Published private(set) var deviceLines: [String] = []
  /// The glasses refused the session because their DAT app is too old for
  /// this SDK: the UI offers the update.
  @Published private(set) var needsGlassesAppUpdate = false

  /// A press of the capture button.
  var onPress: ((CapturePressType) -> Void)?
  /// Recognised speech: text, and whether the recogniser considers it final.
  var onTranscript: ((String, Bool) -> Void)?
  /// Diagnostic lines for the in-app log (errors, permission answers).
  var onLog: ((String) -> Void)?

  private var session: DeviceSession?
  private var camera: Camera?
  private var inputs: Inputs?
  private var speech: Speech?
  private var tokens = ListenerTokenBag()
  private var sessionTasks: [Task<Void, Never>] = []
  private var registrationTask: Task<Void, Never>?
  private var devicesTask: Task<Void, Never>?
  private var deviceTokens: [any AnyListenerToken] = []
  /// When the recogniser was restarted lately: it stops after every
  /// finished sentence, so it is always restarted, only slowed down if it
  /// stops many times in a row in a short time.
  private var speechRestarts: [Date] = []
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

  /// Asks again for the microphone (through Meta AI) and, if granted,
  /// starts on-glasses speech on the running session. For when the first
  /// request timed out or was dismissed.
  func enableVoice() async {
    guard let session, camera != nil, speech == nil else { return }
    guard await access(.microphone) == .granted else { return }
    guard self.session === session else { return }
    attachSpeech(to: session)
  }

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
    speech = nil
    buttonReady = false
    speechReady = false
    speechRestarts = []
    cameraRestarts = 0
    cameraRestarting = false
    streamingSince = nil
    latest.clear()
    status = newStatus
  }

  /// Camera first (required), then microphone (only voice commands need it),
  /// then the camera stream. Button and speech follow the first frame.
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
    let microphone = await access(.microphone)
    if microphone != .granted {
      log("Microphone not granted (\(microphone)): voice commands off, the button works.")
    }
    guard self.session === session else { return }  // disconnected meanwhile
    attachCamera(to: session, thenSpeech: microphone == .granted)
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

  private func attachCamera(to session: DeviceSession, thenSpeech hearsYou: Bool) {
    guard camera == nil else { return }
    // Medium (504x896) at 7 fps: plenty for Claude, gentle on Bluetooth.
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
          Task { @MainActor in self?.attachControls(to: session, speech: hearsYou) }
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

  /// Starts the recogniser again. The glasses stop it after each finished
  /// sentence, so this runs all the time; only a burst of stops (more than
  /// 10 in a minute) earns a pause, never a permanent give-up.
  private func restartSpeech(_ recogniser: Speech) {
    let now = Date()
    speechRestarts = speechRestarts.filter { now.timeIntervalSince($0) < 60 } + [now]
    let delay: Double = speechRestarts.count > 10 ? 10 : 0.3
    if delay > 1 { log("Speech: stopping too often, pausing \(Int(delay)) s before listening again") }
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard let self, self.speech === recogniser else { return }
      recogniser.start()
    }
  }

  /// Brings the camera stream back after an error (such as
  /// videoStreamingError) or an unexpected stop, so the coach and the
  /// planner keep seeing. Button and speech stay attached to the session.
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
      self.attachCamera(to: session, thenSpeech: false)
    }
  }

  /// JPEG of the most recent frame, or nil if there is none newer than `maxAge`
  /// (the glasses were taken off or folded).
  func latestJPEG(maxAge: TimeInterval = 5) -> Data? {
    guard let snapshot = latest.get(), Date().timeIntervalSince(snapshot.arrivedAt) <= maxAge,
          let image = snapshot.frame.makeUIImage()
    else { return nil }
    return image.jpegData(compressionQuality: 0.7)
  }

  // MARK: - Button and speech

  private func attachControls(to session: DeviceSession, speech hearsYou: Bool) {
    attachButton(to: session)
    if hearsYou { attachSpeech(to: session) }
  }

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

  private func attachSpeech(to session: DeviceSession) {
    guard speech == nil else { return }
    do {
      guard let newSpeech = try session.addSpeech() else {
        log("These glasses expose no speech recognition (Speech).")
        return
      }
      speech = newSpeech
      newSpeech.transcriptionPublisher.listen { [weak self] result in
        let text = result.text
        let isFinal = result.isFinal
        Task { @MainActor in self?.onTranscript?(text, isFinal) }
      }.store(in: tokens)
      newSpeech.statePublisher.listen { [weak self] state in
        Task { @MainActor in
          guard let self else { return }
          switch state {
          case .started:
            self.speechReady = true
          case .stopped:
            // Born stopped: only restart a recogniser that had been running.
            guard self.speechReady, self.speech === newSpeech else { break }
            self.speechReady = false
            self.restartSpeech(newSpeech)
          default:
            break
          }
        }
      }.store(in: tokens)
      newSpeech.errorPublisher.listen { [weak self] error in
        Task { @MainActor in self?.log("Speech error: \(error)") }
      }.store(in: tokens)
      newSpeech.start()
    } catch {
      log("Speech not attached: \(error)")
    }
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
