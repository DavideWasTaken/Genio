# Hardware test checklist (Ray-Ban Meta)

Unit tests cover the task engine, the protocol and the session logic with
mocks. What follows needs real glasses, a real iPhone and a real network. Run
it after installing a build; note the result and the Settings → Log for
anything that fails.

Setup: iPhone on iOS 18+, glasses charged and updated, paired in iOS
Bluetooth settings **and** linked in Meta AI (Developer Mode on), Gemini API
key in Settings.

## 1. Glasses and audio route

- [ ] *Connect glasses*: Camera and Button pills turn green.
- [ ] Settings → Test audio and camera → *Start the audio test*:
  - [ ] Microphone shows the glasses (Bluetooth HFP), not "iPhone Microphone".
  - [ ] Speaking into the glasses moves the bar; tapping the glasses' frame does too.
  - [ ] The chime is heard on the glasses, not the phone.
- [ ] *Take a frame*: a fresh image (< 2 s) of what the glasses see.
- [ ] Audio test again **while the camera is streaming**: route and level unchanged (HFP and DAT video at the same time).

## 2. Session

- [ ] Press the capture button: chime, status "Live" in Settings → Log, microphone pill green.
- [ ] Say "ciao": Genio answers in the chosen Gemini voice, on the glasses.
- [ ] Transcripts of you and Genio appear on the main screen.
- [ ] Talk over Genio while it speaks: it stops at once (barge-in) and listens.
- [ ] Genio does not hear itself (no answers to its own words) with the volume up.

## 3. Task flow

- [ ] "Aiutami a [task with 4+ steps]": Genio says a title, the number of steps and step 1; the task card shows the plan.
- [ ] "Fatto": step 2. "Torna indietro": step 1 again. "Fatto" again.
- [ ] Finish a step **without saying anything**, keep it in view: Genio moves on by itself after a few seconds (two consistent looks), not instantly.
- [ ] Look away / cover the camera while a step is unfinished: no advance.
- [ ] Do a step wrong (wrong part, wrong orientation): a short, cautious warning; not repeated every few seconds.
- [ ] Questions: "quale vite devo usare?", "è giusto così?", "non trovo il pulsante": answers use what the camera shows.
- [ ] "Ho un modello diverso" / "non ho quell'attrezzo": the remaining steps change (task card updates); completed steps stay.
- [ ] Stay silent and keep working on a long step: Genio stays quiet (no narration).
- [ ] "Nuovo compito": the task is dropped and Genio asks what's next.
- [ ] Last step done: congratulations, task card shows Done.

## 4. Interruptions and recovery

- [ ] "Genio stop" (or press the button): short goodbye, chime, GENIO off; task card shows *paused*.
- [ ] Press again: Genio resumes from the same step without repeating the whole plan.
- [ ] Force-quit the app mid-task, reopen: the task is restored (paused); press the button to resume.
- [ ] Turn on airplane mode for 10 s mid-task: status "Reconnecting", then "Live" again; the task is unchanged and Genio continues.
- [ ] Keep a session running more than 10 minutes: no audible break (goAway → resumption).
- [ ] Fold or take off the glasses: GENIO switches off; task kept.
- [ ] Phone call during a session: audio pauses; after the call Genio works again (or reconnects).
- [ ] Wrong API key: GENIO does not start; an iOS-voice line says the key is missing/invalid; no retry loop in the Log.
- [ ] Send the app to the background for 30 s and back: video resumes (frames sent keeps growing).

## 5. Settings

- [ ] Change the voice and the voice language: applied at the next start.
- [ ] Coach off: steps still advance on "fatto" and on Gemini's own looks; the Log shows no coach lines.
- [ ] Settings → Log while GENIO is on: frames sent grow by about one a second; tokens grow.

## Known risks to watch

- Glasses firmware that drops HFP while DAT streams video (section 1, last item).
- The phone's microphone used instead of the glasses' (orange warning on the main screen).
- Echo with voice processing unavailable (Log: "voice processing unavailable").
