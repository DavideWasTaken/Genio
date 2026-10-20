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
    case lookClosely = "look_closely"
    case listSavedTasks = "list_saved_tasks"
    case resumeTask = "resume_task"
    case rememberFact = "remember_fact"
    case forgetFact = "forget_fact"
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
  /// Takes a sharp still and asks a vision model `question` about it (see
  /// look_closely). Nil: close looks are not available.
  public var onCloseLook: ((String) async -> CloseLookResult)?

  /// What the app's close look produced.
  public enum CloseLookResult: Equatable, Sendable {
    /// `source`: "photo" (taken by the glasses) or "frame" (the sharpest
    /// recent video frame).
    case answer(CloseLookAnswer, source: String)
    /// No usable image (camera stopped, no recent frame).
    case noImage
    case failed(String)
  }

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
        name: Name.lookClosely.rawValue,
        description: "Takes a sharp, high-resolution photo with the glasses and looks at it carefully to answer a precise question: printed text, a model or part number, a size, which screw or cable, whether a part is fully seated or faces the right way. The live frames are small and often blurred: use this instead of guessing about small details. Before calling, tell the user in a few words to hold still and bring it close (\"Fammi vedere da vicino, stai fermo un attimo\"). It takes a few seconds. The camera must be on.",
        parameters: .object(properties: [
          ("question", .string(description: "What exactly to find out, in English, e.g. \"What model number is printed on the label?\".")),
        ], required: ["question"]),
        behavior: .blocking),
      FunctionDeclaration(
        name: Name.listSavedTasks.rawValue,
        description: "Lists earlier tasks that were not finished (set aside with \"new task\", or interrupted), newest first, with their progress and id. Call it when the user wants to pick up something they were doing.",
        parameters: nil, behavior: .blocking),
      FunctionDeclaration(
        name: Name.resumeTask.rawValue,
        description: "Picks up an earlier unfinished task by its id (from list_saved_tasks or the instruction). The task in progress, if any, is saved for later. Then tell the user where they are.",
        parameters: .object(properties: [("task_id", .string(description: "The task's id as listed."))], required: ["task_id"]),
        behavior: .blocking),
      FunctionDeclaration(
        name: Name.rememberFact.rawValue,
        description: "Remembers a lasting fact about the user for future conversations: what they own (\"Bosch washing machine\"), their tools, skill level, preferences. Only when they say it or ask you to remember; never sensitive data.",
        parameters: .object(properties: [("fact", .string(description: "The fact, one short sentence in the conversation language."))], required: ["fact"]),
        behavior: .blocking),
      FunctionDeclaration(
        name: Name.forgetFact.rawValue,
        description: "Forgets remembered facts that contain the given words, when the user asks you to forget something or a fact is no longer true.",
        parameters: .object(properties: [("text", .string(description: "Words that identify the fact."))], required: ["text"]),
        behavior: .blocking),
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
    case .listSavedTasks: result = savedTasks()
    case .resumeTask: result = resume(call.args)
    case .rememberFact: result = rememberFact(call.args)
    case .forgetFact: result = forgetFact(call.args)
    case .turnOnCamera: result = camera(on: true)
    case .turnOffCamera: result = camera(on: false)
    case .lookClosely: result = refused("look_closely takes a few seconds and is answered on its own")
    case nil: result = refused("unknown function \(call.name)")
    }
    return FunctionResponse(id: call.id, name: call.name, response: .object(result))
  }

  /// Whether a call takes time (a photo and a vision request): the caller
  /// runs it with `handleSlow` without holding up the conversation.
  public nonisolated static func isSlow(_ call: FunctionCall) -> Bool {
    call.name == Name.lookClosely.rawValue
  }

  /// Runs a slow call (see `isSlow`); any other call is handled at once.
  public func handleSlow(_ call: FunctionCall) async -> FunctionResponse {
    guard Self.isSlow(call) else { return handle(call) }
    let result = await closeLook(call.args)
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
      return refused("a task is in progress (\(current.goal), step \(current.current + 1) of \(current.steps.count)). Ask the user whether to set it aside (it is saved and can be resumed later); call again with replace_current true only if they say so.")
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

  private func savedTasks() -> [String: JSONValue] {
    let summary = engine.memorySummary()
    guard !summary.savedTasks.isEmpty,
          let data = try? JSONEncoder().encode(summary.savedTasks),
          let list = try? JSONSerialization.jsonObject(with: data)
    else { return ["saved_tasks": .array([]), "instruction": .string("There are no unfinished earlier tasks.")] }
    return ["saved_tasks": JSONValue(any: list)]
  }

  private func resume(_ args: JSONValue) -> [String: JSONValue] {
    guard let id = args["task_id"]?.stringValue else { return refused("task_id is missing") }
    switch engine.resumeTask(idPrefix: id) {
    case .success(let task):
      let cameraOn = cameraIsOn() || onCameraRequest?(true) == true
      return accepted([
        "goal": .string(task.goal),
        "current_step": .number(Double(task.current + 1)),
        "total_steps": .number(Double(task.steps.count)),
        "step_text": .string(task.currentStep ?? ""),
        "camera": .string(cameraOn ? "on" : "unavailable"),
        "instruction": .string("Task resumed. Tell the user, briefly, which task and the current step."),
      ])
    case .failure:
      return refused("no unfinished task with id \(id). Call list_saved_tasks.")
    }
  }

  private func rememberFact(_ args: JSONValue) -> [String: JSONValue] {
    guard let fact = args["fact"]?.stringValue, !fact.trimmingCharacters(in: .whitespaces).isEmpty else {
      return refused("fact is missing")
    }
    return engine.rememberFact(fact)
      ? accepted(["instruction": .string("Remembered. Acknowledge in a few words.")])
      : accepted(["instruction": .string("Already known.")])
  }

  private func forgetFact(_ args: JSONValue) -> [String: JSONValue] {
    guard let text = args["text"]?.stringValue else { return refused("text is missing") }
    let removed = engine.forgetFact(text)
    return accepted(["forgotten": .number(Double(removed))])
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
                       "instruction": .string("The camera is starting; frames arrive in a second or two. Say in a few words that you are turning it on, then stop: the app tells you as soon as you can see, and then you answer.")])
    }
    if let task = engine.task, !task.finished, !engine.paused {
      return refused("a task is in progress and the coach needs the camera. Keep it on until the task ends.")
    }
    _ = onCameraRequest?(false)
    return accepted(["camera": .string("off")])
  }

  private func closeLook(_ args: JSONValue) async -> [String: JSONValue] {
    guard let question = args["question"]?.stringValue, !question.trimmingCharacters(in: .whitespaces).isEmpty else {
      return refused("question is missing")
    }
    guard let onCloseLook else { return refused("close looks are not available. Answer from the live frames, saying you are not sure.") }
    guard cameraIsOn() else { return refused("the camera is off. Call turn_on_camera first, then look_closely again.") }
    switch await onCloseLook(question) {
    case .answer(let found, let source):
      var result = accepted([
        "answer": .string(found.answer),
        "text_seen": .string(found.textSeen),
        "confident": .bool(found.confident),
        "image": .string(source),
      ])
      if found.confident {
        result["instruction"] = .string("Tell the user the answer in one or two short sentences, quoting text and numbers exactly. If it shows a step done or a mistake, use the functions as usual.")
      } else {
        result["retry_hint"] = .string(found.retryHint)
        result["instruction"] = .string("The photo did not show it clearly. Do not guess: say so briefly, tell the user how to show it better (retry_hint), then call look_closely again.")
      }
      return result
    case .noImage:
      return refused("there was no sharp image to look at (the camera has no recent frame). Ask the user to look at it again, then retry.")
    case .failed(let why):
      return refused("the close look failed (\(why)). Answer from the live frames if you can, and say you are not sure.")
    }
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
        ? "Say it now, briefly and cautiously (\"careful\", \"check that…\"), keeping the key words of your message: you may be wrong."
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
