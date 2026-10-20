# Genio architecture

Genio is a step-by-step coach, not a general assistant. Gemini Live gives it
ears, eyes and a voice; the task engine keeps it on the task.

## Components

```
GenioController ─┬─ GlassesManager        DAT SDK: session, camera (latest frame, photos), capture button
                 ├─ AudioManager          audio session + engine (the only one)
                 ├─ LiveConversationEngine ── GeminiLiveSession (GenioCore) ── WebSocket
                 │                          └─ TaskTools (GenioCore) ── TaskEngine
                 ├─ CoachEngine ── GeminiVisionCoach (GenioCore) ── REST
                 ├─ (look_closely) ── GeminiCloseLook (GenioCore) ── REST
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
| `LiveInstructions` | the system instruction (with the task), context recovery, app events, warnings |
| `RemarkDelivery` | keeps a warning until Genio's words show it was said; resends it once |
| `GeminiVisionCoach` | the coach's generateContent request/response and model choice |
| `GeminiCloseLook` | the close look's generateContent request/response (high media resolution) |
| `FramePacer`, `PCM`, `Sharpness` | video sampling policy; 16-bit PCM conversion; picking the sharpest frame |

## The task engine is the source of truth

Models propose, the engine decides. Gemini can call:

| Function | What the engine checks |
| --- | --- |
| `turn_on_camera`, `turn_off_camera` | the camera is off at the start; off is refused while a task is in progress |
| `look_closely` | a question is given and the camera is on; answered when the photo has been looked at (see Close look) |
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
the start-up second). Gemini then stops talking: as soon as the first frame
has been sent, the app tells it (`LiveInstructions.cameraReady`, with the
user's latest words) and it answers, so the user never repeats the question;
after 20 s without a frame it is told the camera did not start. If Genio says
it turns the camera on without calling the function (`CameraPhrase`), the app
turns it on itself. A camera start that sends no frame within 7 s is
restarted. Genio counts as speaking until its voice has finished playing,
not just until Gemini's turn is complete, so the follow-up waits for the
end of "Accendo la fotocamera" and never longer. `create_task_plan`
turns the camera on for the coach, and it goes
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

## Warnings that arrive

Once the engine lets a remark through, it is recorded as said and never
proposed again for that step, so a lost warning would be lost for good.
`RemarkDelivery` keeps it until Genio's own words show it was said:

- A coach remark is sent only when nobody is talking: Genio silent for 1 s,
  the user for 1 s (hazard) or 2.5 s (mistake). One warning in the air at a
  time, hazards first. A remark Gemini reports itself (`report_observation`
  with `speak`) is watched the same way, without being sent.
- The next turn Genio finishes is checked: the remark's key words (four
  letters or more, not "attento", "careful" and the like, compared by their
  first five letters) must be in its transcript, at least one and a third of
  them. Gemini is asked to keep the key words.
- An interrupted turn, a turn about something else, or nothing said within
  10 s counts as not heard: the remark goes out once more ("the user did not
  hear this warning"), then it is given up.
- A remark expires (hazard 30 s, mistake 25 s after it was seen), and a
  mistake is dropped when the step changes; a hazard is kept.
- No silent step check runs while a warning waits or is in the air: the
  check would mute Genio's reply, and the warning with it.

The Log shows each one: "Warning", "Warning heard", "Warning not heard,
saying it again", "Warning dropped".

## Close look

The live frames are small (≤ 768 px, about one a second) and often blurred by
head movement: enough to follow a task, not to read a label. For a precise
question (printed text, a model number, a screw size, whether a part is
seated), Gemini calls `look_closely` after asking the user to hold still:

1. `GlassesManager` asks the glasses for a photo (`stream.capturePhoto`,
   JPEG) while the stream goes on, and meanwhile keeps the sharpest video
   frame of the next 1.2 s (variance of the Laplacian on a 320 px grayscale
   copy, `Sharpness`). The photo is used if it arrives within 4 s, scaled to
   ≤ 2048 px; otherwise the sharpest frame. A failed photo
   (`photoCaptureFailed`) does not restart the camera.
2. `GeminiCloseLook` sends it with the question, the goal and the current
   step to the coach's model at `MEDIA_RESOLUTION_HIGH`, with a JSON schema:
   `answer`, `text_seen` (exactly as written), `confident`, `retry_hint`.
3. The result goes back to Gemini Live as the function's answer. When not
   confident, Gemini is told not to guess, to tell the user how to show it
   better, and to look again.

The call takes a few seconds, so it runs on its own task: the conversation's
audio and events keep flowing, and the result is dropped if Gemini cancelled
the call meanwhile. Silent checks and warnings wait until it is answered.

## Silent step checks

Gemini Live answers only to input: frames alone never make it speak. So while
a step is in progress and the camera is on, after 10 s of quiet (nobody spoke
for 4 s, Genio not speaking), the app sends a `[Genio check]` message: look at
the latest frames, call `propose_step_completion` if the step is clearly
done, `report_observation` for a clear mistake, otherwise nothing
(`StepCheckPolicy`, restarted at every new step). The reply to a check is
muted: it is played only after a function result that advanced the step or
allowed a remark, and the mute ends when the user speaks or the app sends
anything else. The user does not have to say "done": Gemini's looks and the
coach's count toward the same two-look confirmation, and a confirmed step is
announced at once.

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
