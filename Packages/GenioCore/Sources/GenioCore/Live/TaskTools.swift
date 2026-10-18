import Foundation

/// The functions Gemini Live may call, and their checks. The model proposes;
/// TaskEngine decides. Every argument is validated, and a refusal says why
/// so the model can correct itself.
///
/// Commands only the user may give (done, back, new task, pause) carry the
/// user's own words, and are checked against what the microphone actually
/// transcribed: the model cannot invent a "done" the user never said.
@MainActor
public final class TaskTools {
  public enum Name: String, CaseIterable {
    case getTaskState = "get_task_state"
    case createTaskPlan = "create_task_plan"
    case proposePlanRevision = "propose_plan_revision"
    case proposeStepCompletion = "propose_step_completion"
    case reportObservation = "report_observation"
    case userConfirmedStep = "user_confirmed_step"
    case goBackStep = "go_back_step"
    case startNewTask = "start_new_task"
    case pauseGuidance = "pause_guidance"
    case turnOnCamera = "turn_on_camera"
    case turnOffCamera = "turn_off_camera"
  }

  public let engine: TaskEngine
  /// What the user said recently (input transcription, last ~20 s).
  public var recentUserSpeech: () -> String = { "" }
  /// The user asked to pause: the caller ends the live session after the
  /// model's goodbye.
  public var onPauseRequested: (() -> Void)?
  /// A remark the engine let through: shown in the log.
  public var onRemark: ((String, RemarkKind) -> Void)?
  /// Turns the glasses camera on (true) or off (false); returns false if it
  /// cannot (glasses not connected). The camera starts off in a session.
  public var onCameraRequest: ((Bool) -> Bool)?
  /// Whether the camera is streaming now.
  public var cameraIsOn: () -> Bool = { false }

  public init(engine: TaskEngine) {
    self.engine = engine
  }

  // MARK: - Declarations

  public nonisolated static var declarations: [FunctionDeclaration] {
    let stepNumber = Schema.integer(description: "1-based number of the step, as listed by get_task_state.")
    let userWords = Schema.string(description: "The user's own words that asked for this, quoted exactly as they said them.")
    let steps = Schema.array(
      description: "Short, concrete steps, one sentence each, in the conversation language, doable one at a time with busy hands.",
      items: .string(description: "One step."))
    return [
      FunctionDeclaration(
        name: Name.getTaskState.rawValue,
        description: "Returns the task in progress: goal, every step with its status (done, current, upcoming), what the user changed, recent observations and remarks already made. Call it whenever unsure where the user is.",
        parameters: nil, behavior: .blocking),
      FunctionDeclaration(
        name: Name.createTaskPlan.rawValue,
        description: "Proposes a plan for the hands-on task the user asked for: 3 to 12 steps. Base the steps on what the camera shows (device, brand, tools); if you cannot see enough, make the first step a quick check. The app validates it and starts guidance only if accepted.",
        parameters: .object(properties: [
          ("goal", .string(description: "A 2-5 word title of the task.")),
          ("steps", steps),
          ("replace_current", .boolean(description: "True only if the user explicitly asked to drop the task in progress and start this one.")),
        ], required: ["goal", "steps"]),
        behavior: .blocking),
      FunctionDeclaration(
        name: Name.proposePlanRevision.rawValue,
        description: "Proposes new steps from the current step to the end, when the plan does not fit (different model, missing tool, a step that does not apply). Completed steps cannot change and from_step must be the current step.",
        parameters: .object(properties: [
          ("from_step", stepNumber),
          ("steps", steps),
          ("reason", .string(description: "What the user said or what you saw that makes the plan wrong.")),
        ], required: ["from_step", "steps", "reason"]),
        behavior: .blocking),
      FunctionDeclaration(
        name: Name.proposeStepCompletion.rawValue,
        description: "Reports that the camera clearly shows the current step finished. Give concrete visual evidence. One look is not enough: the app advances only after consistent confirmations, and tells you when it does. Never tell the user a step is done unless the result says advanced.",
        parameters: .object(properties: [
          ("step_number", stepNumber),
          ("evidence", .string(description: "What exactly in the image shows the step done.")),
        ], required: ["step_number", "evidence"]),
        behavior: .blocking),
      FunctionDeclaration(
        name: Name.reportObservation.rawValue,
        description: "Reports what the camera shows about the current step: a hazard, a clear mistake, progress, or that the view is inadequate. The result says whether to speak: if speak is false, stay silent.",
        parameters: .object(properties: [
          ("step_number", stepNumber),
          ("verdict", .string(description: "What the frame shows about the step.", enumValues: StepVerdict.allCases.map(\.rawValue))),
          ("kind", .string(description: "hazard: heat, blade, electricity, spill, falling part. mistake: wrong part, order or orientation. info: worth remembering only.", enumValues: RemarkKind.allCases.map(\.rawValue))),
          ("evidence", .string(description: "What in the image supports this.")),
          ("message", .string(description: "The one short sentence you would say to the user, or empty.")),
        ], required: ["step_number", "verdict", "kind", "evidence"]),
        behavior: .blocking),
      FunctionDeclaration(
        name: Name.userConfirmedStep.rawValue,
        description: "The user said they finished the current step (\"done\", \"fatto\", \"next\", \"avanti\"). Moves to the next step.",
        parameters: .object(properties: [("step_number", stepNumber), ("user_words", userWords)], required: ["step_number", "user_words"]),
        behavior: .blocking),
      FunctionDeclaration(
        name: Name.goBackStep.rawValue,
        description: "The user asked to go back to the previous step.",
        parameters: .object(properties: [("user_words", userWords)], required: ["user_words"]),
        behavior: .blocking),
      FunctionDeclaration(
        name: Name.startNewTask.rawValue,
        description: "The user asked to drop the task in progress and start something else (\"new task\", \"nuovo compito\"). Then ask what they want to do.",
        parameters: .object(properties: [("user_words", userWords)], required: ["user_words"]),
        behavior: .blocking),
      FunctionDeclaration(
        name: Name.turnOnCamera.rawValue,
        description: "Turns the glasses camera on. It is off when a session starts. Call it as soon as you need to see: a practical task, \"look at this\", \"is this right?\", \"what do you see?\". It takes a second or two: meanwhile tell the user briefly that you are turning it on (\"Accendo la fotocamera\"), then look. Never describe what you see while it is off.",
        parameters: .object(properties: [("reason", .string(description: "Why you need to see."))], required: ["reason"]),
        behavior: .blocking),
      FunctionDeclaration(
        name: Name.turnOffCamera.rawValue,
        description: "Turns the glasses camera off when the practical part is over and the conversation no longer needs it, to save battery. A task in progress keeps it on.",
        parameters: nil, behavior: .blocking),
      FunctionDeclaration(
        name: Name.pauseGuidance.rawValue,
        description: "The user asked Genio to stop or pause (\"Genio stop\", \"basta\", \"pausa\"). The task is kept for later. Say a short goodbye.",
        parameters: .object(properties: [("user_words", userWords)], required: ["user_words"]),
        behavior: .blocking),
    ]
  }

  // MARK: - Dispatch

  /// Runs one call and returns its response (never throws: errors are
  /// responses the model can read).
  public func handle(_ call: FunctionCall) -> FunctionResponse {
    let result: [String: JSONValue]
    switch Name(rawValue: call.name) {
    case .getTaskState: result = state()
    case .createTaskPlan: result = createPlan(call.args)
    case .proposePlanRevision: result = revise(call.args)
    case .proposeStepCompletion: result = completion(call.args)
    case .reportObservation: result = observation(call.args)
    case .userConfirmedStep: result = userConfirmed(call.args)
    case .goBackStep: result = userCommand(call.args) { engine.userWentBack() }
    case .startNewTask: result = userCommand(call.args) { engine.clear() }
    case .pauseGuidance:
      result = userCommand(call.args) {
        engine.pause()
        onPauseRequested?()
      }
    case .turnOnCamera: result = camera(on: true)
    case .turnOffCamera: result = camera(on: false)
    case nil: result = refused("unknown function \(call.name)")
    }
    return FunctionResponse(id: call.id, name: call.name, response: .object(result))
  }

  // MARK: - Functions

  private func state() -> [String: JSONValue] {
    guard let snapshot = engine.snapshot(),
          let data = try? JSONEncoder().encode(snapshot),
          let object = try? JSONSerialization.jsonObject(with: data)
    else { return ["task": .null, "instruction": .string("No task in progress. Ask the user what they want to do.")] }
    return ["task": JSONValue(any: object)]
  }

  private func createPlan(_ args: JSONValue) -> [String: JSONValue] {
    guard let goal = args["goal"]?.stringValue else { return refused("goal is missing") }
    guard let steps = strings(args["steps"]) else { return refused("steps must be a list of strings") }
    if let current = engine.task, !current.finished, args["replace_current"]?.boolValue != true {
      return refused("a task is in progress (\(current.goal), step \(current.current + 1) of \(current.steps.count)). Ask the user whether to drop it; call again with replace_current true only if they say so.")
    }
    switch engine.startTask(goal: goal, steps: steps, strict: true) {
    case .success(let task):
      // The coach checks the steps through the camera.
      let cameraOn = cameraIsOn() || onCameraRequest?(true) == true
      return accepted([
        "camera": .string(cameraOn ? "on" : "unavailable"),
        "current_step": .number(1),
        "total_steps": .number(Double(task.steps.count)),
        "step_text": .string(task.steps[0]),
        "instruction": .string("Plan accepted. Tell the user the title, the number of steps and the first step, briefly."),
      ])
    case .failure(let error):
      return refused(error.description)
    }
  }

  private func camera(on: Bool) -> [String: JSONValue] {
    if on {
      if cameraIsOn() {
        return accepted(["camera": .string("on"), "instruction": .string("The camera is already on: look.")])
      }
      guard onCameraRequest?(true) == true else {
        return refused("the camera is not available (glasses not connected). Tell the user.")
      }
      return accepted(["camera": .string("starting"),
                       "instruction": .string("The camera is starting; frames arrive in a second or two. Tell the user briefly you are turning it on, then look.")])
    }
    if let task = engine.task, !task.finished, !engine.paused {
      return refused("a task is in progress and the coach needs the camera. Keep it on until the task ends.")
    }
    _ = onCameraRequest?(false)
    return accepted(["camera": .string("off")])
  }

  private func revise(_ args: JSONValue) -> [String: JSONValue] {
    guard let from = args["from_step"]?.intValue else { return refused("from_step must be an integer") }
    guard let steps = strings(args["steps"]) else { return refused("steps must be a list of strings") }
    let reason = args["reason"]?.stringValue ?? ""
    switch engine.reviseRemaining(fromStep: from - 1, steps: steps, reason: reason, strict: true) {
    case .success(let task):
      return accepted([
        "current_step": .number(Double(task.current + 1)),
        "step_text": .string(task.currentStep ?? ""),
        "total_steps": .number(Double(task.steps.count)),
        "instruction": .string("Plan updated. Tell the user, in one sentence, what changed and the current step."),
      ])
    case .failure(let error):
      return refused(error.description)
    }
  }

  private func completion(_ args: JSONValue) -> [String: JSONValue] {
    guard let number = args["step_number"]?.intValue else { return refused("step_number must be an integer") }
    let evidence = args["evidence"]?.stringValue ?? ""
    return describe(engine.proposeCompletion(stepNumber: number, evidence: evidence, source: .live))
  }

  private func observation(_ args: JSONValue) -> [String: JSONValue] {
    guard let task = engine.task else { return refused("there is no task in progress") }
    guard let number = args["step_number"]?.intValue else { return refused("step_number must be an integer") }
    guard let verdict = args["verdict"]?.stringValue.flatMap(StepVerdict.init(rawValue:)) else {
      return refused("verdict must be one of \(StepVerdict.allCases.map(\.rawValue).joined(separator: ", "))")
    }
    let kind = args["kind"]?.stringValue.flatMap(RemarkKind.init(rawValue:)) ?? .info
    let evidence = args["evidence"]?.stringValue ?? ""
    let message = args["message"]?.stringValue ?? ""
    let outcome = engine.observe(StepObservation(
      stepIndex: number - 1, revision: task.revision, verdict: verdict,
      evidence: evidence, source: .live, at: Date()))
    if outcome == .ignored(.stale) {
      return describe(outcome)
    }
    var result = describe(outcome)
    let speak = engine.shouldSay(message, kind: kind)
    if speak { onRemark?(message, kind) }
    result["speak"] = .bool(speak)
    if outcome != .confirmed {
      result["instruction"] = .string(speak
        ? "Say it now, briefly and cautiously (\"careful\", \"check that…\"): you may be wrong."
        : "Stay silent.")
    }
    return result
  }

  private func userConfirmed(_ args: JSONValue) -> [String: JSONValue] {
    guard let task = engine.task, !task.finished else { return refused("there is no step in progress") }
    guard let number = args["step_number"]?.intValue else { return refused("step_number must be an integer") }
    guard number == task.current + 1 else {
      return refused("step \(number) is not the current step; the current step is \(task.current + 1): \(task.currentStep ?? "")")
    }
    return userCommand(args) { engine.userConfirmedStep() }
  }

  private func userCommand(_ args: JSONValue, _ action: () -> Void) -> [String: JSONValue] {
    let words = args["user_words"]?.stringValue ?? ""
    guard Self.saidRecently(words, in: recentUserSpeech()) else {
      return refused("the microphone did not hear the user say that. Ask the user to confirm out loud.")
    }
    action()
    var result = accepted([:])
    if let task = engine.task {
      result["current_step"] = .number(Double(task.current + 1))
      result["step_text"] = .string(task.currentStep ?? "")
      result["finished"] = .bool(task.finished)
    } else {
      result["task"] = .null
    }
    return result
  }

  private func describe(_ outcome: CompletionVerifier.Outcome) -> [String: JSONValue] {
    switch outcome {
    case .confirmed:
      guard let task = engine.task else { return accepted(["advanced": .bool(true)]) }
      if task.finished {
        return accepted([
          "advanced": .bool(true), "finished": .bool(true),
          "instruction": .string("All steps are done: congratulate the user in one short sentence."),
        ])
      }
      return accepted([
        "advanced": .bool(true),
        "current_step": .number(Double(task.current + 1)),
        "step_text": .string(task.currentStep ?? ""),
        "instruction": .string("The step is confirmed done. Tell the user the next step, briefly."),
      ])
    case .pending(let have, let need):
      return [
        "status": .string("pending"), "advanced": .bool(false),
        "confirmations": .number(Double(have)), "needed": .number(Double(need)),
        "instruction": .string("Noted. Keep watching; do not tell the user the step is done yet."),
      ]
    case .reset:
      return ["status": .string("reset"), "advanced": .bool(false)]
    case .ignored(let reason):
      var result: [String: JSONValue] = ["status": .string("ignored"), "advanced": .bool(false), "reason": .string(reason.rawValue)]
      if reason == .stale, let task = engine.task {
        result["current_step"] = .number(Double(task.current + 1))
        result["instruction"] = .string("That is not the current step. The current step is \(task.current + 1): \(task.currentStep ?? "").")
      }
      if reason == .noEvidence { result["instruction"] = .string("Describe the visual evidence.") }
      return result
    }
  }

  // MARK: - Helpers

  private func accepted(_ extra: [String: JSONValue]) -> [String: JSONValue] {
    extra.merging(["status": .string("accepted")]) { current, _ in current }
  }

  private func refused(_ why: String) -> [String: JSONValue] {
    ["status": .string("refused"), "error": .string(why)]
  }

  private func strings(_ value: JSONValue?) -> [String]? {
    guard let items = value?.arrayValue else { return nil }
    let texts = items.compactMap(\.stringValue)
    return texts.count == items.count ? texts : nil
  }

  /// Whether `words` (as quoted by the model) match what was transcribed:
  /// at least half of their words, and at least two when they have two or
  /// more, must appear there. Accents and case are ignored.
  public nonisolated static func saidRecently(_ words: String, in transcript: String) -> Bool {
    let quoted = normalizedWords(words)
    guard !quoted.isEmpty else { return false }
    let heard = Set(normalizedWords(transcript))
    guard !heard.isEmpty else { return false }
    let found = quoted.filter(heard.contains).count
    return found >= min(2, quoted.count) && Double(found) / Double(quoted.count) >= 0.5
  }

  nonisolated static func normalizedWords(_ text: String) -> [String] {
    let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    return folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
  }
}
