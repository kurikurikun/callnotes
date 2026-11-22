# CallNotes — development notes

Menu-bar call recorder for move-ment (Chris, kurikurikun). Records any online call (system audio + mic via ScreenCaptureKit), transcribes on the Mac with WhisperKit, summarises with Claude. No bot joins the call. README.md has the architecture, file by file.

## Where the code lives

- Master copy: github.com/kurikurikun/callnotes (public, MIT). Each Mac works in a clone at `~/Developer/callnotes`, never in iCloud (iCloud turns `.build` into cloud-only placeholders and re-stamps xattrs that codesign rejects).
- A SessionStart hook on Chris's Macs fast-forwards the clone from GitHub when a session starts. Commit and push when work is done so the other Mac gets it.
- Never commit recordings, transcripts, the Claude API key (it lives in the Keychain, service `co.move-ment.callnotes`) or anything under `~/Library/Application Support/CallNotes`.

## Build & release

- `./build.sh` — dev build into /Applications. Needs macOS 15+, Apple Silicon, Xcode (WhisperKit via SwiftPM).
- `./release.sh 0.3 "what changed"` — pulls, sets `AppInfo.version` in `Sources/CallNotes/Version.swift`, commits, `./build.sh --release` (Developer ID sign, notarize with keychain profile `peripheralspeed-notary`, staple, Gatekeeper gate), tags `vX.Y`, publishes a GitHub Release with BOTH `CallNotes-X.Y.zip` and `CallNotes.zip` (move-ment.co's download button and the in-app updater use `releases/latest/download/CallNotes.zip`).
- Notarized releases only from Chris's M1 Mac mini (cert + notary profile there, Team ID PNDN4CQY5T).

## Auto-update (Sources/CallNotes/Update.swift)

- Checks `releases/latest` at launch, every time the menu opens (`NSMenu.didBeginTracking`, throttled to 30 s) and hourly. A newer version shows "vX is out — update now" near the bottom of the menu.
- Install downloads the zip, refuses it unless it's signed by Team ID PNDN4CQY5T, then a detached shell swaps /Applications/CallNotes.app after the app quits and relaunches it.
- Disabled while recording or while a job (saving/transcribing/summarising) runs — never quit mid-call.
- Test hook: `/Applications/CallNotes.app/Contents/MacOS/CallNotes --install-update`. Log: `log stream --predicate 'subsystem == "co.move-ment.callnotes"' --info`.
