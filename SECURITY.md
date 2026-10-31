# Security

Local Dictation runs speech models on your device. It can also clean text on your device. History is off unless you turn it on. It holds up to 100 entries. The app removes temp audio after use. Model sources and revisions must be on an allowlist. Before load, the app checks each file against a pinned manifest. It checks size and SHA-256. It also limits file size and tree entries. A hash finds a mismatch with the manifest. It does not hide audio or text. Use made-up audio and text in reports.

Local audio and transcripts are plaintext protected by account permissions. Use your Mac’s disk encryption to protect saved files. The native app has an ad-hoc code signature. This lets the installer check whether its files changed. It does not prove who made the app. The build is not notarized.

Report security issues through [GitHub private vulnerability reporting](https://github.com/gmperkinsmba/local-dictation/security/advisories/new).
