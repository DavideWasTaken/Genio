import AVFoundation
import CallKit

/// A GENIO session presented to iOS as a call (CallKit). iOS does not let an
/// app switch the microphone on while it is in the background, unless it is
/// a call: so the glasses' button can start GENIO with the phone in a pocket.
/// The call also routes audio to the glasses like a phone call, shows
/// "Genio" in the Dynamic Island, and ending it there switches GENIO off.
@MainActor
final class CallSession: NSObject {
  /// The user ended the call from the system UI (or iOS ended it).
  var onEndedBySystem: (() -> Void)?
  var onLog: ((String) -> Void)?

  private let provider: CXProvider
  private let controller = CXCallController()
  private var callID: UUID?
  private var endingOurselves = false
  private var activation: CheckedContinuation<Bool, Never>?
  /// iOS activated the audio session for the current call (it can happen
  /// before start() starts waiting for it).
  private var audioActive = false

  override init() {
    let configuration = CXProviderConfiguration()
    configuration.supportsVideo = false
    configuration.maximumCallGroups = 1
    configuration.maximumCallsPerCallGroup = 1
    configuration.supportedHandleTypes = [.generic]
    configuration.includesCallsInRecents = false
    provider = CXProvider(configuration: configuration)
    super.init()
    provider.setDelegate(self, queue: .main)
  }

  var isActive: Bool { callID != nil }

  /// Starts the call and returns once iOS has activated the audio session
  /// (true), or false if iOS refused or did not answer in time.
  func start() async -> Bool {
    if callID != nil { return true }
    let id = UUID()
    callID = id
    audioActive = false
    let action = CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: "Genio"))
    action.isVideo = false
    do {
      try await controller.request(CXTransaction(action: action))
    } catch {
      onLog?("Call: iOS refused to start it (\(error.localizedDescription))")
      callID = nil
      return false
    }
    // iOS activates the audio session shortly after the action is performed.
    let activated = audioActive ? true : await withCheckedContinuation { continuation in
      activation = continuation
      Task { [weak self] in
        try? await Task.sleep(for: .seconds(5))
        self?.finishActivation(false)
      }
    }
    if !activated {
      onLog?("Call: the audio session was not activated in time")
      end()
    }
    return activated
  }

  func end() {
    guard let id = callID else { return }
    endingOurselves = true
    let action = CXEndCallAction(call: id)
    Task {
      do {
        try await controller.request(CXTransaction(action: action))
      } catch {
        onLog?("Call: ending failed (\(error.localizedDescription))")
        provider.reportCall(with: id, endedAt: Date(), reason: .remoteEnded)
      }
    }
    callID = nil
  }

  private func finishActivation(_ ok: Bool) {
    activation?.resume(returning: ok)
    activation = nil
  }
}

extension CallSession: CXProviderDelegate {
  nonisolated func providerDidReset(_ provider: CXProvider) {
    MainActor.assumeIsolated {
      callID = nil
      finishActivation(false)
    }
  }

  nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    // Configure, never activate: CallKit activates the session itself.
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
      try? session.setPreferredSampleRate(16_000)
      try? session.setPreferredIOBufferDuration(0.02)
    } catch {
      MainActor.assumeIsolated { onLog?("Call: audio category not set (\(error.localizedDescription))") }
    }
    provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
    action.fulfill()
    provider.reportOutgoingCall(with: action.callUUID, connectedAt: Date())
  }

  nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    action.fulfill()
    MainActor.assumeIsolated {
      let ours = endingOurselves
      endingOurselves = false
      callID = nil
      finishActivation(false)
      if !ours {
        onLog?("Call: ended from the system")
        onEndedBySystem?()
      }
    }
  }

  nonisolated func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
    action.fulfill()
  }

  nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    action.fulfill()
  }

  nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    MainActor.assumeIsolated {
      onLog?("Call: audio session active")
      audioActive = true
      finishActivation(true)
    }
  }

  nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    MainActor.assumeIsolated {
      audioActive = false
      onLog?("Call: audio session released")
    }
  }
}
