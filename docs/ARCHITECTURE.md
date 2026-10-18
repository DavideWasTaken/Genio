# Genio architecture

Genio is a step-by-step coach, not a general assistant. Gemini Live gives it
ears, eyes and a voice; the task engine keeps it on the task.

## Components

```
GenioController ─┬─ GlassesManager        DAT SDK: session, camera (latest frame), capture button
                 ├─ AudioManager          audio session + engine (the only one)
                 ├─ LiveConversationEngine ── GeminiLiveSession (GenioCore) ── WebSocket
                 │                          └─ TaskTools (GenioCore) ── TaskEngine
                 ├─ CoachEngine ── GeminiVisionCoach (GenioCore) ── REST
                 └─ TaskEngine (GenioCore) ── FileTaskStore
```

`Packages/GenioCore` holds everything that does not need UIKit or the Meta SDK,
so it builds and tests on macOS (`swift test`):

| Type | Role |
| --- | --- |
| `GenioTask` | goal, steps, current step, `revision`, completion times, user notes, remarks |
| `TaskEngine` | the source of truth; validates and applies every change; emits `TaskEvent`s; persists |
| `CompletionVerifier` | when camera evidence is enough to call a step done |
| `TaskStore` / `FileTaskStore` | atomic JSON in Application Support |
| `LiveMessages` | the Live API wire format (setup, realtimeInput, toolResponse; server events) |
| `GeminiLiveSession` | an actor: one WebSocket at a time, resumption, goAway, backoff, once-only tool calls |
| `TaskTools` | function declarations for Gemini and their validation against the engine |
| `LiveInstructions` | the system instruction (with the task), context recovery, app events |
| `GeminiVisionCoach` | the coach's generateContent request/response and model choice |
| `FramePacer`, `PCM` | video sampling policy; 16-bit PCM conversion |

## The task engine is the source of truth

Models propose, the engine decides. Gemini can call:

| Function | What the engine checks |
| --- | --- |
| `turn_on_camera`, `turn_off_camera` | the camera is off at the start; off is refused while a task is in progress |
| `get_task_state` | — (returns goal, steps with status, notes, recent observations and remarks) |
| `create_task_plan` | goal not empty, 3–12 steps, each short; refuses to replace a task in progress unless `replace_current` |
| `propose_plan_revision` | must start at the current step (completed steps are history, skipping is impossible); total ≤ 12 |
| `propose_step_completion` | about the current step and revision; needs evidence; counted by the verifier |
| `report_observation` | verdict and kind are valid enums; the engine decides whether the remark is worth saying (`speak`) |
| `user_confirmed_step`, `go_back_step`, `start_new_task`, `pause_guidance` | the quoted user words must match the microphone transcript of the last 20 s |
| `list_saved_tasks`, `resume_task` | only unfinished tasks in the archive; resuming bumps the revision and sets the current task aside |
| `remember_fact`, `forget_fact` | not empty, not a duplicate (case-insensitive), at most 200 characters, 30 facts kept |

All functions are declared `BLOCKING`, so Gemini waits for the engine's answer
before telling the user a step is done or a plan changed. Refusals explain why,
so the model can correct itself.

Every change to the current step or the remaining steps bumps `revision`.
Anything computed for an older revision — a coach verdict that took two
seconds, a late proposal from the model — is dropped as stale.

## Completion: fewer false positives

`CompletionVerifier` advances a step on camera evidence only when:

- the look says `completed` and gives explicit evidence;
- it is about the current step and revision;
- there are 2 such looks (from the coach, from Gemini, or both) at least 2 s
  apart, within 45 s;
- no `not_completed` look came in between (that resets the count).

`uncertain` and `no_view` (looking away, dark, blurred, no recent frame) neither
count nor reset. The user saying "done" bypasses the verifier: the user is the
authority.

## Gemini Live session

- Endpoint: `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=…`
- Setup: `models/gemini-3.8-live` (configurable), `responseModalities: [AUDIO]`, a prebuilt voice, system instruction with the task, tool declarations, automatic activity detection with `START_OF_ACTIVITY_INTERRUPTS` (barge-in), input and output transcription, the `googleSearch` tool (grounding for current facts and model manuals), `contextWindowCompression.slidingWindow` (without it an audio+video session ends after 2 minutes), `sessionResumption`.
- Input: `realtimeInput.audio` (16 kHz 16-bit mono PCM, ~64 ms chunks), `realtimeInput.video` (JPEG, ≤ 1 fps, ≤ 768 px), `realtimeInput.text` for app events (`[Genio] …`).
- Output: `serverContent` audio (24 kHz PCM) played as it arrives; `interrupted` flushes playback at once; transcripts feed the UI and the user-words check; `toolCall` → TaskTools → `toolResponse`.
- Connections last ~10 minutes: on `goAway` the session reconnects at once with the latest resumable handle. On a drop it retries with backoff (0.5 s, 1 s, 2 s… ≤ 20 s, jitter), up to 8 times; an invalid key (close 1008) is not retried. After 2 failed resumptions it starts fresh and sends the task state (`contextLost`).
- Tool calls are delivered once per id; cancelled calls are never answered; each call is answered once.

**Local state vs Gemini's context.** The engine's state is saved on the phone and
survives anything. Gemini's conversation memory lives on Google's side and
survives reconnects through resumption handles (valid 2 h); when it is lost,
the system instruction and a `[Genio]` recovery message carry the task again.

## Audio

`AudioManager` is the only place that touches `AVAudioSession` and
`AVAudioEngine`:

- Live: `.playAndRecord` / `.voiceChat` with `.allowBluetoothHFP`, so the
  glasses' microphone and speakers are used; voice processing on the input node
  cancels Genio's own voice; input converted to 16 kHz mono 16-bit; output
  played on a 24 kHz player node.
- The route is read, not assumed: the UI and the log show whether the
  microphone is the glasses (Bluetooth HFP) or the phone, and warn when it
  changes.
- DAT Speech is not used: Gemini does the listening, so nothing is recognised
  twice. AVSpeechSynthesizer is used only for lines Gemini cannot say (no key,
  no connection).
- Each GENIO session is a CallKit call (`CallSession`): iOS refuses to start
  the microphone from the background otherwise. CallKit configures and
  activates the session (`configureLive(activatedByCall:)` skips its own
  activation); ending the call from the system UI switches GENIO off. If iOS
  refuses the call, the session starts without it (fine on screen).
- Standby (glasses connected, GENIO off): silent looped playback, mixed with
  other apps, so the app stays alive in the background for the button.
- Interruptions (calls, Siri), route changes, engine configuration changes and
  media-services resets restart or rebuild the engine.

## Video

The DAT camera streams 504×896 at 7 fps, and only when needed. A session
starts with the camera off; Gemini turns it on with `turn_on_camera` when the
user asks for something practical (it says "Accendo la fotocamera" to cover
the start-up second), `create_task_plan` turns it on for the coach, and it goes
off when the task ends or with `turn_off_camera` (refused while a task is in
progress). The camera test turns it on while its page is open. When the
glasses connect it runs just long enough to deliver a first frame (the button
is attached after it). Only the newest frame is kept.
`FramePacer` takes at most one frame per interval (≤ 1 fps), only if it is
fresher than 1.5 s, and only when the previous one has finished encoding and
sending (no queue: a slow network drops frames instead of sending old ones).
Encoding (UIImage → scaled JPEG) runs on a background task. Video keeps
flowing with the app in the background (phone in a pocket). Metrics: frames sent and dropped, average
latency from frame arrival to send.

## Coach

`CoachEngine` runs every 6 seconds (`Tuning.coachInterval`) while a step is
in progress and Genio is not speaking. It sends the newest frame (≤ 1024 px)
and the step to a separate Gemini model through `generateContent` with a JSON
schema (`verdict`, `evidence`, `say`, `kind`). The verdict becomes an
observation for the engine; a remark is relayed to Gemini Live (which says it
in its own voice) only if the engine allows it: hazards at most every 5 s,
mistakes every 15 s, never a repeat, never `info`. The coach is always on: it
is what checks the steps; Gemini Live alone rarely looks unprompted.

## Memory

- **Archive.** Starting a new task or saying "new task" moves the current task
  to an archive (newest first, 20 kept); a finished task goes there too.
  Unfinished ones can be resumed by id (the first 8 characters of the UUID).
- **Facts.** Short sentences about the user that Gemini stores with
  `remember_fact` when the user says something lasting or asks it to remember.
- Both go into the system instruction at every session start (`MemorySummary`:
  the facts and up to 8 resumable tasks with their progress), so "let's pick up
  the bookshelf" works without a tool round trip, and are saved with the task.

## Persistence and lifecycle

- The task, pause state, recent observations, archive and facts are saved after
  every change (`Application Support/Genio/task.json`) and the task is restored
  paused at launch.
- Glasses disconnected: GENIO switches off, the task stays.
- Internet lost: the session reconnects with backoff; the task engine and the
  UI keep working; after too many failures GENIO switches off and says why in
  the iOS voice.
- App in the background with GENIO on: everything keeps running; the open
  microphone (audio background mode) keeps the app alive.
- App in the background with GENIO off: AudioManager's *standby* mode plays
  silence (`.playback` + `.mixWithOthers`) while the glasses are connected,
  so iOS does not suspend the app and the capture button still arrives. iOS
  can still terminate the app; nothing more is promised.
- Settings changes (voice, voice language, coach) apply at the next start.
- Settings are kept to what a user needs: key, voice, voice language, the
  button press that starts GENIO, hardware test, log. The vision coach is always on. Model, coach pace and video rate
  are fixed in code (`LiveConversationEngine.defaultModel`, `Tuning`).

## Security

The Gemini API key is entered by the user, stored in the keychain
(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), sent only to Google's
endpoints (query parameter for the WebSocket, as documented; `x-goog-api-key`
header for REST), and never logged. For a public release, use ephemeral tokens
minted by a backend (`BidiGenerateContentConstrained?access_token=…`).
