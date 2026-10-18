import XCTest
@testable import GenioCore

@MainActor
final class TaskEngineTests: XCTestCase {
  private var clock = Date(timeIntervalSince1970: 1_000_000)
  private var events: [TaskEvent] = []

  private func makeEngine(store: TaskStore? = nil) -> TaskEngine {
    let engine = TaskEngine(store: store, now: { [unowned self] in self.clock })
    engine.onEvent = { [unowned self] in self.events.append($0) }
    return engine
  }

  private let fourSteps = ["Spegni la lavatrice", "Apri lo sportellino", "Svita il filtro", "Pulisci il filtro"]

  func testStrictPlanNeedsThreeToTwelveSteps() {
    let engine = makeEngine()
    XCTAssertEqual(engine.startTask(goal: "Filtro", steps: ["uno", "due"], strict: true).failureValue, .tooFewSteps(min: 3))
    let thirteen = (1...13).map { "passo \($0)" }
    XCTAssertEqual(engine.startTask(goal: "Filtro", steps: thirteen, strict: true).failureValue, .tooManySteps(max: 12))
    XCTAssertEqual(engine.startTask(goal: "  ", steps: fourSteps, strict: true).failureValue, .emptyGoal)
    XCTAssertNil(engine.task)
    XCTAssertTrue(events.isEmpty)
  }

  func testLenientPlanKeepsTheOldBehaviour() throws {
    let engine = makeEngine()
    let thirteen = (1...13).map { "passo \($0)" }
    let task = try engine.startTask(goal: "Lungo", steps: thirteen + ["  "], strict: false).get()
    XCTAssertEqual(task.steps.count, 12)
    XCTAssertEqual(try engine.startTask(goal: "Corto", steps: ["solo uno"], strict: false).get().steps, ["solo uno"])
  }

  func testUserCommandsMoveThroughThePlan() throws {
    let engine = makeEngine()
    try engine.startTask(goal: "Filtro", steps: fourSteps, strict: true).get()
    engine.userConfirmedStep()
    XCTAssertEqual(engine.task?.current, 1)
    XCTAssertEqual(engine.task?.revision, 1)
    engine.userWentBack()
    XCTAssertEqual(engine.task?.current, 0)
    for _ in 0..<4 { engine.userConfirmedStep() }
    XCTAssertTrue(engine.task?.finished == true)
    engine.userConfirmedStep()  // nothing past the end
    XCTAssertEqual(engine.task?.current, 4)
    guard case .finished = events.last else { return XCTFail("expected .finished, got \(String(describing: events.last))") }
    engine.userWentBack()  // back from "all done" returns to the last step
    XCTAssertEqual(engine.task?.current, 3)
    engine.clear()
    XCTAssertNil(engine.task)
    XCTAssertEqual(events.last, .cleared)
  }

  func testRevisionStartsAtTheCurrentStepOnly() throws {
    let engine = makeEngine()
    try engine.startTask(goal: "Filtro", steps: fourSteps, strict: true).get()
    engine.userConfirmedStep()  // now on step 2 (index 1)
    XCTAssertEqual(engine.reviseRemaining(fromStep: 0, steps: ["x"], reason: nil, strict: true).failureValue, .wrongStartStep(current: 1))
    XCTAssertEqual(engine.reviseRemaining(fromStep: 2, steps: ["x"], reason: nil, strict: true).failureValue, .wrongStartStep(current: 1))
    let tooMany = (1...12).map { "nuovo \($0)" }
    XCTAssertEqual(engine.reviseRemaining(fromStep: 1, steps: tooMany, reason: nil, strict: true).failureValue, .tooManySteps(max: 12))

    let revision = engine.task!.revision
    let task = try engine.reviseRemaining(fromStep: 1, steps: ["Premi il pulsante blu", "Togli il filtro"], reason: "ho un modello diverso", strict: true).get()
    XCTAssertEqual(task.steps, ["Spegni la lavatrice", "Premi il pulsante blu", "Togli il filtro"])
    XCTAssertEqual(task.current, 1)
    XCTAssertEqual(task.revision, revision + 1)
    XCTAssertEqual(task.userNotes, ["ho un modello diverso"])
    XCTAssertEqual(events.last, .planRevised(task, fromStep: 1))
  }

  func testStateIsSavedAndRestoredPaused() throws {
    let store = MemoryTaskStore()
    let engine = makeEngine(store: store)
    try engine.startTask(goal: "Filtro", steps: fourSteps, strict: true).get()
    engine.userConfirmedStep()
    XCTAssertGreaterThanOrEqual(store.saveCount, 2)

    let restored = makeEngine(store: store)
    XCTAssertEqual(restored.task?.current, 1)
    XCTAssertEqual(restored.task?.goal, "Filtro")
    XCTAssertTrue(restored.paused)
  }

  func testFinishedTasksAreNotRestored() throws {
    let store = MemoryTaskStore()
    let engine = makeEngine(store: store)
    try engine.startTask(goal: "Filtro", steps: ["a", "b", "c"], strict: true).get()
    for _ in 0..<3 { engine.userConfirmedStep() }
    XCTAssertNil(makeEngine(store: store).task)
  }

  func testFileStoreRoundTrip() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("task.json")
    let store = FileTaskStore(url: url)
    let engine = makeEngine(store: store)
    try engine.startTask(goal: "Filtro", steps: fourSteps, strict: true).get()
    engine.userConfirmedStep()
    let loaded = try XCTUnwrap(FileTaskStore(url: url).load())
    XCTAssertEqual(loaded.task?.current, 1)
    XCTAssertEqual(loaded.task?.steps, fourSteps)
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
  }

  func testRemarksAreRateLimitedAndNotRepeated() throws {
    let engine = makeEngine()
    XCTAssertFalse(engine.shouldSay("Attento", kind: .mistake), "no task, nothing to say")
    try engine.startTask(goal: "Filtro", steps: fourSteps, strict: true).get()
    XCTAssertTrue(engine.shouldSay("Quella è la vite sbagliata", kind: .mistake))
    clock += 5
    XCTAssertFalse(engine.shouldSay("Gira il pezzo", kind: .mistake), "too soon after a remark")
    XCTAssertTrue(engine.shouldSay("Attento, il ferro è caldo", kind: .hazard), "hazards may come sooner")
    clock += 20
    XCTAssertFalse(engine.shouldSay("quella è la vite sbagliata", kind: .mistake), "already said")
    XCTAssertFalse(engine.shouldSay("La vite è a croce", kind: .info), "info is never spoken")
    XCTAssertTrue(engine.shouldSay("Gira il pezzo", kind: .mistake))
    XCTAssertEqual(engine.snapshot()?.recentRemarks.count, 3)
  }

  func testSnapshotForTheModel() throws {
    let engine = makeEngine()
    try engine.startTask(goal: "Filtro", steps: fourSteps, strict: true).get()
    engine.userConfirmedStep()
    let snapshot = try XCTUnwrap(engine.snapshot())
    XCTAssertEqual(snapshot.currentStep, 2)
    XCTAssertEqual(snapshot.steps.map(\.status), ["done", "current", "upcoming", "upcoming"])
    XCTAssertTrue(snapshot.text.contains("[NOW] 2. Apri lo sportellino"))
    let json = String(data: try JSONEncoder().encode(snapshot), encoding: .utf8)!
    XCTAssertTrue(json.contains("\"current_step\":2"))
  }
}

extension Result {
  var failureValue: Failure? {
    if case .failure(let error) = self { return error }
    return nil
  }
}
