# CallNotes

Menu-bar app for move-ment: records any online call (Meet, Teams, Zoom, anything that plays audio on the Mac), transcribes it on the Mac with WhisperKit, and writes a summary with Claude. No bot joins the call. Spec: `CallNotes_SPEC.md` (Downloads), Nov 2026.

## Build

- `./build.sh` – builds, signs (see Signing) and installs `/Applications/CallNotes.app`. `./build.sh --zip` also writes `build/CallNotes-<v>.zip`.
- Needs macOS 15+, Apple Silicon, Xcode (SwiftPM pulls WhisperKit 1.1.1).
- Signing: Developer ID if present; otherwise the self-signed "CallNotes Local Signing" cert in the login keychain (made Nov 2026, 10 years), which keeps the app identity stable so macOS keeps its permissions across rebuilds. With neither, ad-hoc signing and permissions are re-asked every build.
- Self-test (no call needed): `CallNotes --selftest ours.aiff theirs.aiff -outputFolder /tmp/x` fakes a crashed two-track recording with speaker echo, then runs recovery → .m4a → transcription → merge and prints `transcript.md`.

## How it works (Sources/CallNotes)

- `Recorder.swift` – ScreenCaptureKit stream (2×2 px, 1 fps video ignored) with `capturesAudio` + `captureMicrophone`, `excludesCurrentProcessAudio`. Each track is appended as raw 48 kHz mono Int16 PCM in `~/Library/Application Support/CallNotes/Sessions/<id>/`, fsynced every 2 s – no header to finalise, so a crash loses at most ~2 s. Both tracks share one timeline (t0 at start); gaps are filled with silence so timestamps line up.
- `Sessions.swift` – `session.json` per running call (heartbeat every 10 s). Anything left in `Sessions/` at launch is offered for recovery. `finalize` writes `mic.m4a`, `system.m4a`, mixed `call.m4a`, `meta.json` into `<output>/YYYY-MM-DD_HHMM_<title>/`, and deletes the raw files only after `call.m4a` reads back at full length. Retention deletes only the three .m4a files.
- `Transcriber.swift` – WhisperKit, model downloaded once to `Application Support/CallNotes/Models` (path remembered so it loads offline). Each track is split at pauses (≥ 0.3 s) into utterances; language is detected per utterance, and every 4 s inside utterances longer than 8 s, restricted to ja/en in Auto (WhisperKit's built-in per-window detection silently falls back to English, so it isn't used). Same-language neighbours are grouped into ≤28 s chunks and transcribed with that language fixed; segment starts are moved to the first sound. Merge: drops lines that sit in silence on their own track (hallucinations); where the same speech is on both tracks (echo: > 60 % of the shorter line's character bigrams in the other, > 50 % time overlap) keeps the louder copy.
- `Summarizer.swift` – Claude Messages API, key in Keychain (`co.move-ment.callnotes`). No key / no network → summary skipped, run later from Recent calls.
- `AppState.swift` – menu state, jobs run one at a time, 2-minute silence warning on the system track, notifications.

## Known limits

- One speaker label per side (no diarisation within the call's other side).
- If the user switches microphone mid-call, ScreenCaptureKit keeps the device chosen at start.
- macOS may periodically re-confirm the screen & system audio permission; that is a system prompt to the Mac's user only – nothing is shown to other participants.
