import Foundation
import GenioCore

/// The periodic vision coach, separate from the conversation: every few
/// seconds it shows the current frame to a Gemini vision model (REST, not
/// the Live session) and hands the verdict to TaskEngine, which decides
/// whether the step is really done (consistent evidence over several looks)
/// and whether a remark is worth saying. The coach never changes the task
/// itself.
@MainActor
final class CoachEngine {
  /// A remark the engine let through, for Gemini Live to say.
  var onRemark: ((String, RemarkKind) -> Void)?
  var onLog: ((String) -> Void)?

  private let engine: TaskEngine
  private let glasses: GlassesManager
  /// The coach to ask, or nil when it cannot run (no key).
  private let makeCoach: () async -> GeminiVisionCoach?
  private let interval: () -> TimeInterval
  /// True while Genio is talking: the coach waits.
  private let isBusy: () -> Bool
  private var loop: Task<Void, Never>?
  private var looking = false

  init(engine: TaskEngine, glasses: GlassesManager, makeCoach: @escaping () async -> GeminiVisionCoach?,
       interval: @escaping () -> TimeInterval, isBusy: @escaping () -> Bool) {
    self.engine = engine
    self.glasses = glasses
    self.makeCoach = makeCoach
    self.interval = interval
    self.isBusy = isBusy
  }

  var isRunning: Bool { loop != nil }

  func start() {
    guard loop == nil else { return }
    loop = Task { [weak self] in
      while !Task.isCancelled {
        guard let seconds = self?.interval() else { return }
        try? await Task.sleep(for: .seconds(seconds))
        guard let self, !Task.isCancelled else { return }
        await self.tick()
      }
    }
  }

  func stop() {
    loop?.cancel()
    loop = nil
  }

  private func tick() async {
    guard !looking, !isBusy(), let snapshot = engine.task, let step = snapshot.currentStep, !engine.paused else { return }
    looking = true
    defer { looking = false }
    guard let coach = await makeCoach() else { return }
    guard case let (image, frameTime)? = await glasses.latestJPEGInBackground(maxAge: 3, maxDimension: 1024, quality: 0.7) else {
      // Nothing recent to look at (glasses off, camera restarting): an
      // inadequate view, which never advances anything.
      engine.observe(StepObservation(stepIndex: snapshot.current, revision: snapshot.revision, verdict: .noView,
                                     evidence: "no recent frame", source: .coach, at: Date()))
      return
    }
    do {
      let verdict = try await coach.coach(
        image: image, goal: snapshot.goal, steps: snapshot.steps,
        current: snapshot.current, recentRemarks: snapshot.recentRemarks)
      // The observation carries the revision it was made for: if the user
      // moved on meanwhile, the engine drops it as stale.
      let outcome = engine.observe(StepObservation(
        stepIndex: snapshot.current, revision: snapshot.revision, verdict: verdict.verdict,
        evidence: verdict.evidence, source: .coach, at: frameTime))
      onLog?("Coach: \(verdict.verdict.rawValue) \"\(step)\" → \(outcome)")
      guard outcome != .ignored(.stale), outcome != .confirmed else { return }
      let remark = verdict.say.trimmingCharacters(in: .whitespacesAndNewlines)
      if !remark.isEmpty, engine.shouldSay(remark, kind: verdict.kind) {
        onRemark?(remark, verdict.kind)
      }
    } catch {
      onLog?("Coach: \(error.localizedDescription)")
    }
  }
}
