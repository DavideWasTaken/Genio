import XCTest
@testable import GenioCore

final class CompletionVerifierTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_000_000)

  private func look(_ verdict: StepVerdict, at seconds: TimeInterval, step: Int = 0, revision: Int = 0,
                    evidence: String = "le viti sono sul tavolo", source: ObservationSource = .coach) -> StepObservation {
    StepObservation(stepIndex: step, revision: revision, verdict: verdict, evidence: evidence, source: source, at: t0 + seconds)
  }

  func testOneLookIsNeverEnough() {
    var verifier = CompletionVerifier()
    XCTAssertEqual(verifier.consider(look(.completed, at: 0), current: 0, revision: 0, stepCount: 3), .pending(have: 1, need: 2))
    XCTAssertEqual(verifier.consider(look(.completed, at: 3), current: 0, revision: 0, stepCount: 3), .confirmed)
  }

  func testLooksAtTheSameMomentCountOnce() {
    var verifier = CompletionVerifier()
    _ = verifier.consider(look(.completed, at: 0), current: 0, revision: 0, stepCount: 3)
    XCTAssertEqual(verifier.consider(look(.completed, at: 0.5, source: .live), current: 0, revision: 0, stepCount: 3), .ignored(.tooSoon))
    XCTAssertEqual(verifier.pendingCount, 1)
  }

  func testNotCompletedResetsUncertainAndNoViewDoNot() {
    var verifier = CompletionVerifier()
    _ = verifier.consider(look(.completed, at: 0), current: 0, revision: 0, stepCount: 3)
    XCTAssertEqual(verifier.consider(look(.uncertain, at: 3), current: 0, revision: 0, stepCount: 3), .ignored(.uncertain))
    XCTAssertEqual(verifier.consider(look(.noView, at: 6), current: 0, revision: 0, stepCount: 3), .ignored(.noView))
    XCTAssertEqual(verifier.pendingCount, 1)
    XCTAssertEqual(verifier.consider(look(.notCompleted, at: 9), current: 0, revision: 0, stepCount: 3), .reset)
    XCTAssertEqual(verifier.consider(look(.completed, at: 12), current: 0, revision: 0, stepCount: 3), .pending(have: 1, need: 2))
  }

  func testCompletionWithoutEvidenceDoesNotCount() {
    var verifier = CompletionVerifier()
    XCTAssertEqual(verifier.consider(look(.completed, at: 0, evidence: "  "), current: 0, revision: 0, stepCount: 3), .ignored(.noEvidence))
  }

  func testStaleLooksAreIgnored() {
    var verifier = CompletionVerifier()
    XCTAssertEqual(verifier.consider(look(.completed, at: 0, step: 0), current: 1, revision: 1, stepCount: 3), .ignored(.stale))
    XCTAssertEqual(verifier.consider(look(.completed, at: 0, step: 1, revision: 0), current: 1, revision: 1, stepCount: 3), .ignored(.stale))
  }

  func testConfirmationsExpireOutsideTheWindow() {
    var verifier = CompletionVerifier(requiredConfirmations: 2, minSpacing: 2, window: 30)
    _ = verifier.consider(look(.completed, at: 0), current: 0, revision: 0, stepCount: 3)
    XCTAssertEqual(verifier.consider(look(.completed, at: 40), current: 0, revision: 0, stepCount: 3), .pending(have: 1, need: 2))
  }

  @MainActor
  func testEngineAdvancesOnlyOnConsistentEvidence() throws {
    var clock = t0
    let engine = TaskEngine(now: { clock })
    var changes: [StepChangeReason] = []
    engine.onEvent = { if case .stepChanged(_, let reason) = $0 { changes.append(reason) } }
    try engine.startTask(goal: "Filtro", steps: ["a", "b", "c"], strict: true).get()

    XCTAssertEqual(engine.proposeCompletion(stepNumber: 1, evidence: "fatto", source: .live), .pending(have: 1, need: 2))
    clock += 3
    XCTAssertEqual(engine.proposeCompletion(stepNumber: 1, evidence: "fatto", source: .live), .confirmed)
    XCTAssertEqual(engine.task?.current, 1)
    XCTAssertEqual(changes, [.verified])

    // A late proposal about step 1 (the model had not caught up): stale.
    clock += 3
    XCTAssertEqual(engine.proposeCompletion(stepNumber: 1, evidence: "fatto", source: .live), .ignored(.stale))
    XCTAssertEqual(engine.task?.current, 1)
  }

  @MainActor
  func testCoachVerdictForAnOldRevisionIsDropped() throws {
    let engine = TaskEngine()
    try engine.startTask(goal: "Filtro", steps: ["a", "b", "c"], strict: true).get()
    let revisionAtSnapshot = engine.task!.revision
    engine.userConfirmedStep()  // the user moved on while the coach was looking
    let outcome = engine.observe(StepObservation(stepIndex: 1, revision: revisionAtSnapshot, verdict: .completed,
                                                 evidence: "x", source: .coach, at: Date()))
    XCTAssertEqual(outcome, .ignored(.stale))
    XCTAssertEqual(engine.task?.current, 1)
  }
}
