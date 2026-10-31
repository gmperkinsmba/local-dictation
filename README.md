# Local Dictation

Local Dictation turns a held shortcut into text you can review and insert into the app you chose. Speech and optional cleanup run locally. You can change the models, edit either result, or leave the text untouched.

Source: [github.com/gmperkinsmba/local-dictation](https://github.com/gmperkinsmba/local-dictation).

## First use

1. Build and open `Local Dictation.app` using the steps below.
2. Pick a speech model and a cleanup model. Apple Speech and cleanup Off need no model download.
3. Select **Select, Install, and Use**. Local Dictation downloads only the models you chose.
4. Allow microphone access. Allow Accessibility access for the global shortcut.
5. Hold **Control + Shift + Space** to speak. Release the shortcut, review both text versions, then choose one to insert.

Speech and cleanup run on this Mac. Apple Speech is used only when macOS reports on-device recognition support. Local Dictation forces on-device recognition and stops if the Mac cannot provide it. It never sends audio to a network speech service.

## Build and run

Requirements: macOS 14 or newer, Xcode Command Line Tools, and an Apple silicon Mac for MLX models. Apple Speech can run on other Macs if the installed macOS version supports on-device recognition for the chosen language.

Install the compiler tools once:

```sh
xcode-select --install
```

Build the menu bar app:

```sh
./build.sh
```

The app is written to `dist/Local Dictation.app`. Install it in your user Applications folder and open it:

```sh
mkdir -p "$HOME/Applications"
ditto "dist/Local Dictation.app" "$HOME/Applications/Local Dictation.app"
open "$HOME/Applications/Local Dictation.app"
```

The app stays in the menu bar; choose Quit Local Dictation from its menu to close it.

If you have an earlier build, quit Fispr Wlow before opening Local Dictation. The new display name keeps the old bundle identifier and settings, so your choices carry over. Remove the old `~/Applications/Fispr Wlow.app` copy after confirming the new app opens.

Apple Speech works without Python. When you choose an MLX model, the app needs Python 3.12. Install it with Homebrew if needed:

```sh
brew install python@3.12
```

The app then creates a private Python environment in `~/Library/Application Support/Fispr Wlow/runtime` and installs the hash-checked runtime lock for the model tools you selected. The locks target Apple silicon and Python 3.12. It does not use a Hugging Face login or token. Model files go in `~/Library/Application Support/Fispr Wlow/models`.

**Compatibility:** The app keeps bundle identifier `com.gmperkinsmba.fisprwlow` and the existing `~/Library/Application Support/Fispr Wlow` folder. This preserves saved settings, downloaded models, and any transcript history you chose to keep.

## Model choices

Download sizes are measured from pinned model files and exclude Python runtime packages. The first Whisper setup also downloads a roughly 139 MB PyTorch wheel and other pinned dependencies. Memory amounts are rough estimates; actual use depends on macOS and other open apps.

| Model | Use | Download | Memory estimate |
| --- | --- | ---: | ---: |
| Apple Speech | Built into macOS; no model download | none | macOS managed |
| Whisper Tiny English, 4-bit | Fastest Whisper option | about 51 MB | about 0.5 GB |
| Whisper Base English, 4-bit | More speech detail | about 81 MB | about 0.8 GB |
| Whisper Large v3 Turbo | Highest quality among these choices | about 1.6 GB | about 4 GB |
| Cleanup Off | Keep recognized words as-is | none | none |
| Qwen3 0.6B, 4-bit | Light punctuation and filler cleanup | about 335 MB | about 1.2 GB |
| Qwen3 1.7B, 4-bit | Better wording and paragraph breaks | about 968 MB | about 2 GB |

The Whisper models support English. Each card shows its model-file download and memory estimate before the app installs it. You can change the choices later in Settings. Model files are pinned to revisions in `Sources/ModelCatalog.swift` and `LocalModelRunner.py`. Downloads exclude Python files and remote model code. Runtime dependency versions and wheel hashes are pinned in `requirements/`.

## Privacy and limits

- Audio is held in a temporary WAV file while local Whisper runs. The file is deleted after transcription or cancellation. Apple Speech reads the microphone stream in memory.
- Transcript history is off by default. Turn it on in Settings to keep the last 100 raw transcripts in this Mac account.
- Cleanup text is shown next to the recognized text. If cleanup changes a recognized number or capitalized name, only the original is offered.
- Insertion checks that the original app is still running and focused. It pastes text without pressing Return. The prior plain-text clipboard item is restored when macOS permits it.
- Global shortcut, microphone, and Apple Speech permissions can be changed in System Settings. If a permission is denied, dictation stops.
- The first version supports English, 90-second captures, and the three shortcut choices listed in Settings.
- Local model install needs an internet connection. Audio and transcript inference do not.

## Checks

Run the local core checks:

```sh
./test.sh
```

The checks use synthetic text and audio only. They do not open the microphone. They cover the model catalog, shortcut matching, session invalidation, focused-field checks, cleanup fact checks, inference output parsing, and safe model download policy.

**Remove the app and its local data**

Quit Local Dictation from its menu, then run:

```sh
rm -r "$HOME/Applications/Local Dictation.app"
rm -r "$HOME/Library/Application Support/Fispr Wlow"
```

The second command removes downloaded models and any transcript history you chose to keep.

## Licenses

Original source code is MIT licensed. See `THIRD_PARTY_NOTICES.md` for runtime and model terms, including the Whisper conversion license note.
