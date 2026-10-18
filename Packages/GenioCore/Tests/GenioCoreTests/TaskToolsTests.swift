import XCTest
@testable import GenioCore

@MainActor
final class TaskToolsTests: XCTestCase {
  private var engine: TaskEngine!
  private var tools: TaskTools!
  private var heard = ""

  override func setUp() async throws {
    engine = TaskEngine()
    // Two looks must be 2 s apart: the tests do not wait.
    engine.verifier = CompletionVerifier(requiredConfirmations: 2, minSpacing: 0, window: 60)
    tools = TaskTools(engine: engine)
    tools.recentUserSpeech = { [unowned self] in self.heard }
  }

  private func call(_ name: TaskTools.Name, _ args: [String: Any] = [:], id: String = UUID().uuidString) -> JSONValue {
    tools.handle(FunctionCall(id: id, name: name.rawValue, args: JSONValue(any: args))).response
  }

  private func plan() {
    let result = call(.createTaskPlan, ["goal": "Pulire il filtro", "steps": ["Spegni", "Apri", "Svita", "Pulisci"]])
    XCTAssertEqual(result["status"], .string("accepted"))
  }

  func testDeclarationsCoverEveryFunction() {
    let names = TaskTools.declarations.map(\.name)
    XCTAssertEqual(Set(names), Set(TaskTools.Name.allCases.map(\.rawValue)))
    let create = TaskTools.declarations.first { $0.name == "create_task_plan" }!.json
    XCTAssertEqual(create["behavior"] as? String, "BLOCKING")
    let parameters = create["parameters"] as? [String: Any]
    XCTAssertEqual(parameters?["type"] as? String, "OBJECT")
  }

  func testCreatePlanIsValidated() {
    XCTAssertEqual(call(.createTaskPlan, ["goal": "X", "steps": ["uno"]])["status"], .string("refused"))
    XCTAssertEqual(call(.createTaskPlan, ["goal": "X", "steps": "non è una lista"])["status"], .string("refused"))
    XCTAssertEqual(call(.createTaskPlan, ["steps": ["a", "b", "c"]])["status"], .string("refused"))
    XCTAssertNil(engine.task)
    plan()
    XCTAssertEqual(engine.task?.steps.count, 4)
  }

  func testAPlanInProgressIsNotReplacedWithoutTheUser() {
    plan()
    let refused = call(.createTaskPlan, ["goal": "Altro", "steps": ["a", "b", "c"]])
    XCTAssertEqual(refused["status"], .string("refused"))
    XCTAssertEqual(engine.task?.goal, "Pulire il filtro")
    XCTAssertEqual(call(.createTaskPlan, ["goal": "Altro", "steps": ["a", "b", "c"], "replace_current": true])["status"], .string("accepted"))
    XCTAssertEqual(engine.task?.goal, "Altro")
  }

  func testCompletionNeedsTwoLooksAndThenTellsTheModel() {
    plan()
    let first = call(.proposeStepCompletion, ["step_number": 1, "evidence": "la spia è spenta"])
    XCTAssertEqual(first["status"], .string("pending"))
    XCTAssertEqual(first["advanced"], .bool(false))
    XCTAssertEqual(engine.task?.current, 0)
    let second = call(.proposeStepCompletion, ["step_number": 1, "evidence": "la spia è ancora spenta"])
    XCTAssertEqual(second["advanced"], .bool(true))
    XCTAssertEqual(second["step_text"], .string("Apri"))
    XCTAssertEqual(engine.task?.current, 1)
  }

  func testTheModelCannotSkipSteps() {
    plan()
    let skip = call(.proposeStepCompletion, ["step_number": 3, "evidence": "il filtro è fuori"])
    XCTAssertEqual(skip["reason"], .string("stale"))
    XCTAssertEqual(call(.proposeStepCompletion, ["step_number": 3, "evidence": "il filtro è fuori"])["advanced"], .bool(false))
    XCTAssertEqual(engine.task?.current, 0)
    heard = "fatto"
    XCTAssertEqual(call(.userConfirmedStep, ["step_number": 2, "user_words": "fatto"])["status"], .string("refused"))
    XCTAssertEqual(call(.proposePlanRevision, ["from_step": 3, "steps": ["x"], "reason": "r"])["status"], .string("refused"))
    XCTAssertEqual(engine.task?.current, 0)
  }

  func testUserCommandsMustHaveBeenHeard() {
    plan()
    heard = "che bella giornata"
    XCTAssertEqual(call(.userConfirmedStep, ["step_number": 1, "user_words": "fatto"])["status"], .string("refused"))
    XCTAssertEqual(engine.task?.current, 0)
    heard = "ok Fatto, vai avanti"
    let accepted = call(.userConfirmedStep, ["step_number": 1, "user_words": "fatto"])
    XCTAssertEqual(accepted["status"], .string("accepted"))
    XCTAssertEqual(engine.task?.current, 1)
    heard = "torna indietro"
    XCTAssertEqual(call(.goBackStep, ["user_words": "torna indietro"])["status"], .string("accepted"))
    XCTAssertEqual(engine.task?.current, 0)
  }

  func testPauseAndNewTask() {
    plan()
    var paused = false
    tools.onPauseRequested = { paused = true }
    heard = "Genio basta"
    XCTAssertEqual(call(.pauseGuidance, ["user_words": "basta"])["status"], .string("accepted"))
    XCTAssertTrue(paused)
    XCTAssertTrue(engine.paused)
    XCTAssertNotNil(engine.task)
    heard = "nuovo compito"
    XCTAssertEqual(call(.startNewTask, ["user_words": "nuovo compito"])["status"], .string("accepted"))
    XCTAssertNil(engine.task)
  }

  func testRevisionThroughTheTool() {
    plan()
    let result = call(.proposePlanRevision, ["from_step": 1, "steps": ["Stacca la spina", "Apri il cassetto"], "reason": "ho un modello diverso"])
    XCTAssertEqual(result["status"], .string("accepted"))
    XCTAssertEqual(engine.task?.steps, ["Stacca la spina", "Apri il cassetto"])
  }

  func testObservationsDecideWhetherToSpeak() {
    plan()
    let hazard = call(.reportObservation, ["step_number": 1, "verdict": "uncertain", "kind": "hazard", "evidence": "fumo", "message": "Attento al fumo"])
    XCTAssertEqual(hazard["speak"], .bool(true))
    let info = call(.reportObservation, ["step_number": 1, "verdict": "uncertain", "kind": "info", "evidence": "vite a croce", "message": "È a croce"])
    XCTAssertEqual(info["speak"], .bool(false))
    let bad = call(.reportObservation, ["step_number": 1, "verdict": "forse", "kind": "info", "evidence": "x"])
    XCTAssertEqual(bad["status"], .string("refused"))
    XCTAssertEqual(engine.observations.count, 2)
  }

  func testStateAndUnknownFunctions() {
    XCTAssertEqual(call(.getTaskState)["task"], .null)
    plan()
    let state = call(.getTaskState)
    XCTAssertEqual(state["task"]?["current_step"]?.intValue, 1)
    XCTAssertEqual(state["task"]?["total_steps"]?.intValue, 4)
    let unknown = tools.handle(FunctionCall(id: "1", name: "turn_on_lights", args: .object([:]))).response
    XCTAssertEqual(unknown["status"], .string("refused"))
  }

  func testCameraTools() {
    var cameraOn = false
    var requests: [Bool] = []
    tools.cameraIsOn = { cameraOn }
    tools.onCameraRequest = { on in requests.append(on); cameraOn = on; return true }
    XCTAssertEqual(call(.turnOnCamera, ["reason": "guardare il filtro"])["camera"], .string("starting"))
    XCTAssertEqual(call(.turnOnCamera, ["reason": "ancora"])["camera"], .string("on"), "already on: no second request")
    XCTAssertEqual(requests, [true])
    plan()
    XCTAssertEqual(call(.turnOffCamera)["status"], .string("refused"), "the coach needs it during a task")
    XCTAssertTrue(cameraOn)
    heard = "nuovo compito"
    _ = call(.startNewTask, ["user_words": "nuovo compito"])
    XCTAssertEqual(call(.turnOffCamera)["camera"], .string("off"))
    XCTAssertFalse(cameraOn)
    tools.onCameraRequest = { _ in false }
    XCTAssertEqual(call(.turnOnCamera, ["reason": "x"])["status"], .string("refused"), "glasses not connected")
  }

  func testAPlanTurnsTheCameraOn() {
    var cameraOn = false
    tools.cameraIsOn = { cameraOn }
    tools.onCameraRequest = { on in cameraOn = on; return true }
    plan()
    XCTAssertTrue(cameraOn)
  }

  func testHeardMatching() {
    XCTAssertTrue(TaskTools.saidRecently("Fatto!", in: "ok... FATTO"))
    XCTAssertTrue(TaskTools.saidRecently("torna indietro", in: "torna un attimo indietro"))
    XCTAssertTrue(TaskTools.saidRecently("perché", in: "perche"))
    XCTAssertFalse(TaskTools.saidRecently("fatto", in: ""))
    XCTAssertFalse(TaskTools.saidRecently("", in: "fatto"))
    XCTAssertFalse(TaskTools.saidRecently("nuovo compito", in: "che compito difficile"), "only half the words")
  }
}

final class VoiceStopTests: XCTestCase {
  func testPhrasesThatNameGenio() {
    XCTAssertTrue(VoiceStop.matches("Genio stop"))
    XCTAssertTrue(VoiceStop.matches("ok, Genio, basta così"))
    XCTAssertTrue(VoiceStop.matches("adesso ferma Genio per favore"))
    XCTAssertTrue(VoiceStop.matches("STOP GENIO!"))
    XCTAssertFalse(VoiceStop.matches("stop"), "a bare stop may be for someone else")
    XCTAssertFalse(VoiceStop.matches("basta con questa vite"))
    XCTAssertFalse(VoiceStop.matches("Genio, quale vite uso?"))
    XCTAssertFalse(VoiceStop.matches("genio"))
  }
}
