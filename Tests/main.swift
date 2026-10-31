import AppKit
import Foundation

@main
enum TestMain {
    static func main() {
        var failures = 0
        func check(_ name: String, _ condition: Bool) {
            if condition { print("ok  \(name)") }
            else { failures += 1; print("FAIL  \(name)") }
        }
        check("speech model catalog has four choices", SpeechModel.allCases.count == 4)
        check("cleanup catalog has three choices", CleanupModel.allCases.count == 3)
        check("Apple Speech needs no downloaded model", SpeechModel.apple.repo == nil)
        check("cleanup off needs no downloaded model", CleanupModel.off.repo == nil)
        check("default speech is on-device Apple Speech", DictationPreferences().speechModel == .apple)
        check("default cleanup is off", DictationPreferences().cleanupModel == .off)
        var sessions = SessionGate()
        let firstSession = sessions.begin()
        let secondSession = sessions.begin()
        check("a new dictation session rejects stale completion", sessions.accepts(secondSession) && !sessions.accepts(firstSession))
        sessions.invalidate()
        check("settings or cancellation invalidates current completion", !sessions.accepts(secondSession))
        var helpers = HelperStartGate()
        helpers.activateSession(10)
        check("active session may launch a helper", helpers.canStart(sessionID: 10, installationID: nil))
        helpers.cancelSession(10)
        check("cancel blocks a delayed session helper before launch", !helpers.canStart(sessionID: 10, installationID: nil))
        let queuedGateLock = NSLock()
        var queuedGate = HelperStartGate()
        queuedGate.activateSession(20)
        let queuedStarted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            usleep(50_000)
            queuedGateLock.lock()
            let mayLaunch = queuedGate.canStart(sessionID: 20, installationID: nil)
            queuedGateLock.unlock()
            if mayLaunch { queuedStarted.signal() }
        }
        queuedGateLock.lock()
        queuedGate.cancelSession(20)
        queuedGateLock.unlock()
        check("queued delayed helper never starts after cancellation", queuedStarted.wait(timeout: .now() + 0.1) == .timedOut)
        helpers.activateSession(11)
        check("next session may launch after prior cancellation", helpers.canStart(sessionID: 11, installationID: nil))
        let installID = UUID()
        check("one installation can claim the helper gate", helpers.beginInstallation(installID))
        check("installation helper may launch while active", helpers.canStart(sessionID: nil, installationID: installID))
        helpers.cancelInstallation(installID)
        check("cancel blocks a delayed installation helper before launch", !helpers.canStart(sessionID: nil, installationID: installID))
        helpers.finishInstallation(installID)
        let retryID = UUID()
        check("installation can retry after cancellation", helpers.beginInstallation(retryID) && helpers.canStart(sessionID: nil, installationID: retryID))
        helpers.shutDown()
        check("shutdown blocks active-session and installation launches", !helpers.canStart(sessionID: 11, installationID: nil) && !helpers.canStart(sessionID: nil, installationID: retryID))
        var captureGeneration = SessionGate()
        let transcribingGeneration = captureGeneration.begin()
        let replacementGeneration = captureGeneration.begin()
        check("new capture rejects transcription finishing after await", !captureGeneration.accepts(transcribingGeneration) && captureGeneration.accepts(replacementGeneration))
        check("default shortcut is Control Shift Space", HotkeyState().label == "Control + Shift + Space")
        check("Right Command shortcut displays its key", HotkeyState(keyCode: 54, control: false, shift: false, option: false, command: true).label == "Right Command")
        let correct = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .shift], timestamp: 0, windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        let wrong = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option], timestamp: 0, windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        check("shortcut matches exact modifiers", HotkeyState().matches(correct))
        check("shortcut rejects different modifiers", !HotkeyState().matches(wrong))
        check("numeric tokens are protected", FactsPreserver.protectedTokens("Pay $125 on 2026-10-31") == FactsPreserver.protectedTokens("Pay $125 on 2026-10-31."))
        check("name and amount changes are detected", FactsPreserver.protectedTokens("Tell Grant it is $125") != FactsPreserver.protectedTokens("Tell Grant it is $150"))
        check("filler removal does not block punctuation cleanup", FactsPreserver.protectedTokens("uh, we met Grant at 10:30") == FactsPreserver.protectedTokens("We met Grant at 10:30."))
        check("local inference response parses after progress output", RuntimeBridge.responseText("Detected language: English\n100% complete\n{\"text\": \"test words\"}\n") == "test words")
        check("local inference response rejects missing JSON", RuntimeBridge.responseText("model loader error\n") == nil)
        let focus = FocusSignature(role: "AXTextArea", subrole: "", valueDigest: Data("draft".utf8), selectedRange: NSRange(location: 3, length: 0))
        let sameFocus = FocusSignature(role: "AXTextArea", subrole: "", valueDigest: Data("draft".utf8), selectedRange: NSRange(location: 3, length: 0))
        let movedSelection = FocusSignature(role: "AXTextArea", subrole: "", valueDigest: Data("draft".utf8), selectedRange: NSRange(location: 4, length: 0))
        let changedValue = FocusSignature(role: "AXTextArea", subrole: "", valueDigest: Data("changed".utf8), selectedRange: NSRange(location: 3, length: 0))
        let secureFocus = FocusSignature(role: "AXSecureTextField", subrole: "AXSecureTextField", valueDigest: Data(), selectedRange: NSRange(location: 0, length: 0))
        check("same focused field and selection match", focus == sameFocus)
        check("changed field selection is rejected", focus != movedSelection)
        check("changed field contents are rejected", focus != changedValue)
        check("secure text fields are rejected", secureFocus.isSecure && !secureFocus.isEditable)
        let revisions = SpeechModel.allCases.compactMap(\.revision) + CleanupModel.allCases.compactMap(\.revision)
        check("model revisions are full commit IDs", revisions.count == 5 && revisions.allSatisfy { $0.count == 40 })
        print("\(failures == 0 ? "All checks passed" : "\(failures) checks failed")")
        if failures > 0 { exit(1) }
    }
}
