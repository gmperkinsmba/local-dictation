# Local Dictation

Mac app that turns a held shortcut into text you can review and insert. Speech and optional cleanup run locally.

## Run

```sh
./build.sh
./install.sh
```

## Test

```sh
./test.sh
```

Run the tests before committing. There is no separate lint step.

## Layout

- Core code: `LocalModelRunner.py`, `model-integrity-manifest.json`, `ModelIntegrity.py`, `Sources/`
- Mac app wrapper, build and install: `build.sh`, `install.sh`
- Installer and runtime safety checks: `install_security.py`
- Dependencies: `requirements-macos-arm64-py312.in`, `requirements-macos-arm64-py312.lock`, `requirements/`
- Tests: `test.sh`, `Tests/`
- Docs: `CONTEXT.md`, `LICENSE`, `README.md`, `SECURITY.md`, `THIRD_PARTY_NOTICES.md`

## Conventions

- `README.md` describes behaviour and limits; `CONTEXT.md` holds the domain terms and rules. Keep both in step with code changes.
- Read `SECURITY.md` before changing request handling, file access, or the installer.
- Demo data, fixtures and examples are made up. Keep them that way.
- Never commit secrets, keys, tokens, or runtime data.
- A behaviour change comes with a test.
