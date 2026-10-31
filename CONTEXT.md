# Context

Local Dictation turns a held keyboard shortcut into reviewed text in the app that had focus when recording began.

First principle: turn speech into clean text locally while users control models, edits, and insertion.

## Records and state

- Speech model choice is the local recognizer selected by the user.
- Cleanup model choice is a local text model selected by the user, or Off.
- Dictation preferences are local app settings. Transcript history is off until enabled.
- A capture is one microphone session, limited to 90 seconds. Apple Speech uses the live stream in memory. Whisper uses a temporary WAV that is deleted after inference or cancellation.
- Model files live in the user's Application Support folder, outside this repository.
- Earlier builds used the display name Fispr Wlow. The display name is now Local Dictation. Keep bundle identifier `com.gmperkinsmba.fisprwlow` and the `~/Library/Application Support/Fispr Wlow` data folder unchanged so existing settings, models, and opt-in history remain available.

## Invariants

- Speech recognition uses Apple Speech only when macOS reports on-device support, with network recognition disabled, or it uses the selected local MLX Whisper model.
- There is no cloud fallback. A missing model or denied permission stops the session with an error.
- Cleanup cannot run commands. Text remains visible for review before the user chooses which version to insert.
- If cleanup changes a recognized number or capitalized name token, the app shows the speech result unchanged.
- Insertion requires the same nonsecure editable field, value, and selection that had focus at capture start. It uses direct accessibility text insertion when supported, or a paste fallback that restores all clipboard types unless the user changes the clipboard. It never sends Return.
- Installed model repositories are revision-pinned and download only weight and data files. Model code is not loaded.
