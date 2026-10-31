import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics
import CryptoKit
import Darwin
import Speech

@MainActor
final class DictationCapture {
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var speechTask: SFSpeechRecognitionTask?
    private var converter: AVAudioConverter?
    private var outputFile: AVAudioFile?
    private var outputURL: URL?
    private var tapInstalled = false
    private var latestSpeech = ""
    private var speechDelivered = false
    private var speechFinalizationWork: DispatchWorkItem?
    private var generation = SessionGate()
    private var maxDurationWork: DispatchWorkItem?
    var onPartial: ((UInt64, String) -> Void)?
    var onSpeechResult: ((UInt64, Result<String, Error>) -> Void)?
    var onLimit: ((UInt64) -> Void)?
    private var sessionID: UInt64 = 0
    private var captureModel: SpeechModel = .apple

    func start(model: SpeechModel, sessionID: UInt64) throws {
        guard !engine.isRunning else { return }
        self.sessionID = sessionID
        self.captureModel = model
        let input = engine.inputNode
        let sourceFormat = input.outputFormat(forBus: 0)
        guard sourceFormat.sampleRate > 0 else { throw CaptureError.microphoneUnavailable }
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        if model != .apple {
            guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else { throw CaptureError.audioConversion }
            self.converter = converter
        } else {
            self.converter = nil
        }
        let captureID = generation.begin()
        outputURL = nil
        outputFile = nil
        if model != .apple {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("fispr-\(UUID().uuidString).wav")
            outputURL = url
            outputFile = try AVAudioFile(forWriting: url, settings: targetFormat.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        }
        latestSpeech = ""
        speechDelivered = false
        speechFinalizationWork?.cancel()

        if model == .apple {
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable else {
                throw CaptureError.appleSpeechUnavailable
            }
            guard recognizer.supportsOnDeviceRecognition else { throw CaptureError.onDeviceSpeechUnavailable }
            let speechRequest = SFSpeechAudioBufferRecognitionRequest()
            speechRequest.shouldReportPartialResults = true
            speechRequest.requiresOnDeviceRecognition = true
            request = speechRequest
            speechTask = recognizer.recognitionTask(with: speechRequest) { [weak self] result, error in
                Task { @MainActor in
                    guard let self, self.generation.accepts(captureID) else { return }
                    if let result {
                        self.latestSpeech = result.bestTranscription.formattedString
                        self.onPartial?(sessionID, self.latestSpeech)
                        if result.isFinal && !self.speechDelivered {
                            self.speechDelivered = true
                            self.speechFinalizationWork?.cancel()
                            self.onSpeechResult?(sessionID, .success(self.latestSpeech))
                            self.cleanupAudio()
                        }
                    } else if let error, !self.speechDelivered {
                        self.speechDelivered = true
                        self.onSpeechResult?(sessionID, .failure(error))
                    }
                }
            }
        }

        input.installTap(onBus: 0, bufferSize: 2_048, format: sourceFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.request?.append(buffer)
            if let converter = self.converter {
                let ratio = 16_000 / max(1, sourceFormat.sampleRate)
                let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
                guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(32, capacity)) else { return }
                var conversionError: NSError?
                var supplied = false
                converter.convert(to: converted, error: &conversionError) { _, status in
                    if supplied { status.pointee = .noDataNow; return nil }
                    supplied = true
                    status.pointee = .haveData
                    return buffer
                }
                if converted.frameLength > 0 { try? self.outputFile?.write(from: converted) }
            }
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        let work = DispatchWorkItem { [weak self] in
            self?.onLimit?(sessionID)
            self?.stopAndTranscribe()
        }
        maxDurationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: work)
    }

    func stopAndTranscribe() {
        guard engine.isRunning else { return }
        maxDurationWork?.cancel()
        maxDurationWork = nil
        request?.endAudio()
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        outputFile = nil
        let inferenceID = generation.current
        let deliveredSession = sessionID
        let model = captureModel
        if model == .apple {
            let fallback = DispatchWorkItem { [weak self] in
                guard let self, self.generation.accepts(inferenceID), !self.speechDelivered else { return }
                self.speechDelivered = true
                if self.latestSpeech.isEmpty { self.onSpeechResult?(deliveredSession, .failure(CaptureError.noSpeech)) }
                else { self.onSpeechResult?(deliveredSession, .success(self.latestSpeech)) }
                self.cleanupAudio()
            }
            speechFinalizationWork = fallback
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: fallback)
            return
        }
        guard let audioURL = outputURL else { onSpeechResult?(deliveredSession, .failure(CaptureError.audioConversion)); return }
        onPartial?(deliveredSession, "Transcribing on this Mac…")
        let worker = Task.detached {
            let result = RuntimeBridge.transcribe(model: model, sessionID: deliveredSession, audioURL: audioURL)
            return result
        }
        Task { @MainActor [weak self] in
            guard let self, self.generation.accepts(inferenceID) else { return }
            let result = await worker.value
            guard self.generation.accepts(inferenceID) else {
                self.removeAudioFile(audioURL)
                return
            }
            self.cleanupAudio(expectedURL: audioURL)
            switch result {
            case .success(let text): self.onSpeechResult?(deliveredSession, .success(text))
            case .failure(let error): self.onSpeechResult?(deliveredSession, .failure(RuntimeError.processFailed(error.message)))
            }
        }
    }

    func cancel() {
        generation.invalidate()
        speechDelivered = true
        maxDurationWork?.cancel()
        maxDurationWork = nil
        speechFinalizationWork?.cancel()
        speechFinalizationWork = nil
        speechTask?.cancel()
        request?.endAudio()
        if engine.isRunning { engine.stop() }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        cleanupAudio()
    }

    private func cleanupAudio(expectedURL: URL? = nil) {
        if let expectedURL {
            removeAudioFile(expectedURL)
            guard outputURL == expectedURL else { return }
        }
        outputFile = nil
        converter = nil
        request = nil
        speechTask = nil
        if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
        outputURL = nil
    }

    private func removeAudioFile(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}

enum CaptureError: LocalizedError {
    case microphoneUnavailable, audioConversion, appleSpeechUnavailable, onDeviceSpeechUnavailable, noSpeech, permissions
    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable: "No microphone input is available."
        case .audioConversion: "The audio could not be prepared for local transcription."
        case .appleSpeechUnavailable: "Apple Speech is unavailable. Choose an installed Whisper model in Settings."
        case .onDeviceSpeechUnavailable: "Apple cannot recognize this language on-device. No audio was sent online. Choose an installed Whisper model."
        case .noSpeech: "No speech was recognized."
        case .permissions: "Allow Microphone, Speech Recognition, and Accessibility access in System Settings."
        }
    }
}

struct FocusSignature: Equatable {
    let role: String
    let subrole: String
    let valueDigest: Data
    let selectedRange: NSRange

    var isSecure: Bool { role == "AXSecureTextField" || subrole == "AXSecureTextField" }
    var isEditable: Bool { ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) && !isSecure }
}

@MainActor
private struct FocusedEditTarget {
    let processID: pid_t
    let element: AXUIElement
    let signature: FocusSignature

    static func capture(processID: pid_t) -> FocusedEditTarget? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(processID)
        guard let element = focusedElement(in: app), let signature = signature(of: element), signature.isEditable else { return nil }
        return FocusedEditTarget(processID: processID, element: element, signature: signature)
    }

    func isStillFocused() -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else { return false }
        let app = AXUIElementCreateApplication(processID)
        guard let current = Self.focusedElement(in: app), CFEqual(current, element),
              let currentSignature = Self.signature(of: current) else { return false }
        return currentSignature == signature
    }

    func insertWithAccessibility(_ text: String) -> Bool {
        var settable = DarwinBoolean(false)
        guard isStillFocused(), AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
    }

    private static func focusedElement(in app: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value else { return nil }
        return (value as! AXUIElement)
    }

    private static func signature(of element: AXUIElement) -> FocusSignature? {
        guard let role = stringAttribute(element, kAXRoleAttribute as CFString),
              let value = stringAttribute(element, kAXValueAttribute as CFString),
              let rawRange = copyAttribute(element, kAXSelectedTextRangeAttribute as CFString) else { return nil }
        let rangeValue = rawRange as! AXValue
        var cfRange = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &cfRange) else { return nil }
        let subrole = stringAttribute(element, kAXSubroleAttribute as CFString) ?? ""
        let digest = Data(SHA256.hash(data: Data(value.utf8)))
        return FocusSignature(role: role, subrole: subrole, valueDigest: digest,
                              selectedRange: NSRange(location: cfRange.location, length: cfRange.length))
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
        copyAttribute(element, name) as? String
    }

    private static func copyAttribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }
}

private struct PasteboardFlavor {
    let type: NSPasteboard.PasteboardType
    let data: Data
}

private struct PasteboardSnapshot {
    let changeCount: Int
    let items: [[PasteboardFlavor]]

    static func capture(_ pasteboard: NSPasteboard) -> PasteboardSnapshot? {
        let items = pasteboard.pasteboardItems ?? []
        var saved: [[PasteboardFlavor]] = []
        for item in items {
            var flavors: [PasteboardFlavor] = []
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                flavors.append(PasteboardFlavor(type: type, data: data))
            }
            guard !flavors.isEmpty else { return nil }
            saved.append(flavors)
        }
        return PasteboardSnapshot(changeCount: pasteboard.changeCount, items: saved)
    }

    func restore(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        guard !items.isEmpty else { return true }
        let copiedItems = items.map { flavors -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for flavor in flavors { item.setData(flavor.data, forType: flavor.type) }
            return item
        }
        return pasteboard.writeObjects(copiedItems)
    }
}

enum RuntimeBridge {
    private static let processLock = NSLock()
    private struct OwnedProcess {
        let process: Process
        let sessionID: UInt64?
        let installationID: UUID?
    }
    private static var ownedProcesses: [UUID: OwnedProcess] = [:]
    private static var helperGate = HelperStartGate()
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Fispr Wlow", isDirectory: true)
    }
    static var modelRoot: URL { support.appendingPathComponent("models", isDirectory: true) }
    private static var runner: URL? { Bundle.main.url(forResource: "LocalModelRunner", withExtension: "py") }
    private static var runtime: URL { support.appendingPathComponent("runtime", isDirectory: true) }
    private static var runtimePython: URL { runtime.appendingPathComponent(".venv/bin/python") }

    static func isInstalled(_ model: SpeechModel) -> Bool { ModelCatalog.installed(model, at: modelRoot) }
    static func isInstalled(_ model: CleanupModel) -> Bool { ModelCatalog.installed(model, at: modelRoot) }

    static func cancelInstall() {
        processLock.lock()
        guard let installationID = helperGate.activeInstallationID else { processLock.unlock(); return }
        helperGate.cancelInstallation(installationID)
        let processes = ownedProcesses.values.filter { $0.installationID == installationID }.map(\.process)
        processLock.unlock()
        processes.forEach { if $0.isRunning { $0.terminate() } }
    }

    static func activateSession(_ sessionID: UInt64) {
        processLock.lock()
        helperGate.activateSession(sessionID)
        processLock.unlock()
    }

    static func cancelSession(_ sessionID: UInt64) {
        processLock.lock()
        helperGate.cancelSession(sessionID)
        let processes = ownedProcesses.values.filter { $0.sessionID == sessionID }.map(\.process)
        processLock.unlock()
        processes.forEach { if $0.isRunning { $0.terminate() } }
    }

    static func terminateActiveProcessAndWait() {
        processLock.lock()
        helperGate.shutDown()
        let processes = ownedProcesses.values.map(\.process)
        processLock.unlock()
        processes.forEach { if $0.isRunning { $0.terminate() } }
        waitForExit(processes, seconds: 2)
        let remaining = processes.filter(\.isRunning)
        remaining.forEach { _ = kill($0.processIdentifier, SIGKILL) }
        waitForExit(remaining, seconds: 1)
    }

    private static func waitForExit(_ processes: [Process], seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while processes.contains(where: \.isRunning) && Date() < deadline { usleep(20_000) }
    }

    static func install(speech: SpeechModel?, cleanup: CleanupModel?, progress: @escaping @Sendable (String) -> Void, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        guard let runner else { completion(.failure(RuntimeError.missingRunner)); return }
        let installationID = UUID()
        processLock.lock()
        let accepted = helperGate.beginInstallation(installationID)
        processLock.unlock()
        guard accepted else { completion(.failure(RuntimeError.installationAlreadyRunning)); return }
        DispatchQueue.global(qos: .utility).async {
            defer {
                processLock.lock()
                helperGate.finishInstallation(installationID)
                processLock.unlock()
            }
            do {
                try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
                if (speech != nil && speech != .apple) || (cleanup != nil && cleanup != .off) {
                    progress("Setting up the private local runtime…")
                    var setupArguments = ["/usr/bin/env", "python3.12", runner.path, "setup", "--runtime", runtime.path, "--root", modelRoot.path]
                    if let speech, speech != .apple { setupArguments.append("--speech") }
                    if let cleanup, cleanup != .off { setupArguments.append("--cleanup") }
                    try run(setupArguments, input: nil, installationID: installationID, output: progress)
                }
                if let speech, speech != .apple {
                    guard let id = speech.repo.map({ _ in speech.rawValue }) else { throw RuntimeError.unknownModel }
                    progress("Installing \(speech.name)…")
                    try run([runtimePython.path, runner.path, "install", "--runtime", runtime.path, "--root", modelRoot.path, "--model", id], input: nil, installationID: installationID, output: progress)
                }
                if let cleanup, cleanup != .off {
                    progress("Installing \(cleanup.name)…")
                    try run([runtimePython.path, runner.path, "install", "--runtime", runtime.path, "--root", modelRoot.path, "--model", cleanup.rawValue], input: nil, installationID: installationID, output: progress)
                }
                completion(.success(()))
            } catch { completion(.failure(error)) }
        }
    }

    static func transcribe(model: SpeechModel, sessionID: UInt64, audioURL: URL) -> Result<String, BackgroundFailure> {
        guard let runner else { return .failure(BackgroundFailure(message: RuntimeError.missingRunner.localizedDescription)) }
        do {
            let output = try run([runtimePython.path, runner.path, "transcribe", "--runtime", runtime.path, "--root", modelRoot.path, "--model", model.rawValue, "--audio", audioURL.path], input: nil, sessionID: sessionID, output: { _ in })
            guard let text = responseText(output), !text.isEmpty else { throw RuntimeError.emptyResult }
            return .success(text)
        } catch { return .failure(BackgroundFailure(message: error.localizedDescription)) }
    }

    static func clean(_ text: String, model: CleanupModel, sessionID: UInt64, completion: @escaping @Sendable (Result<String, Error>) -> Void) {
        guard let runner else { completion(.failure(RuntimeError.missingRunner)); return }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let request = try JSONSerialization.data(withJSONObject: ["text": text])
                let output = try run([runtimePython.path, runner.path, "cleanup", "--runtime", runtime.path, "--root", modelRoot.path, "--model", model.rawValue], input: request, sessionID: sessionID, output: { _ in })
                guard let cleaned = responseText(output), !cleaned.isEmpty else { throw RuntimeError.emptyResult }
                completion(.success(cleaned))
            } catch { completion(.failure(error)) }
        }
    }

    static func responseText(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let text = object["text"] else { continue }
            return text
        }
        return nil
    }

    @discardableResult
    private static func run(_ arguments: [String], input: Data?, sessionID: UInt64? = nil, installationID: UUID? = nil, output: @escaping @Sendable (String) -> Void) throws -> String {
        guard let executable = arguments.first else { throw RuntimeError.missingRunner }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.localizedCaseInsensitiveContains("token") || key.localizedCaseInsensitiveContains("secret") || key.localizedCaseInsensitiveContains("password") || key.localizedCaseInsensitiveContains("api_key") {
            environment.removeValue(forKey: key)
        }
        environment["PATH"] = "/usr/bin:/bin:/opt/homebrew/bin"
        environment["PYTHONNOUSERSITE"] = "1"
        environment["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let inputPipe = Pipe()
        if input != nil { process.standardInput = inputPipe }
        let processID = UUID()
        processLock.lock()
        guard helperGate.canStart(sessionID: sessionID, installationID: installationID) else {
            processLock.unlock()
            throw RuntimeError.cancelled
        }
        do {
            try process.run()
            ownedProcesses[processID] = OwnedProcess(process: process, sessionID: sessionID, installationID: installationID)
        } catch {
            processLock.unlock()
            throw error
        }
        processLock.unlock()
        defer {
            processLock.lock()
            ownedProcesses.removeValue(forKey: processID)
            processLock.unlock()
        }
        let captured = SynchronizedData()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            captured.append(chunk)
            if let text = String(data: chunk, encoding: .utf8) { output(text) }
        }
        if let input {
            inputPipe.fileHandleForWriting.write(input)
            try? inputPipe.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        let remainder = pipe.fileHandleForReading.readDataToEndOfFile()
        captured.append(remainder)
        let text = String(data: captured.snapshot(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { throw RuntimeError.processFailed(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return text
    }
}

private final class SynchronizedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

struct BackgroundFailure: Error, Sendable {
    let message: String
}

enum RuntimeError: LocalizedError {
    case missingRunner, unknownModel, emptyResult, processFailed(String), installationAlreadyRunning, cancelled
    var errorDescription: String? {
        switch self {
        case .missingRunner: "The local model helper is missing. Rebuild the app from this repository."
        case .unknownModel: "That model choice is not supported."
        case .emptyResult: "The local model returned no text. Try again or use another model."
        case .processFailed(let detail): detail.isEmpty ? "The local model process failed." : detail
        case .installationAlreadyRunning: "A model setup is already running. Wait for it to finish or cancel it before starting another."
        case .cancelled: "The local model task was cancelled before it started."
        }
    }
}

struct HotkeyState: Codable {
    var keyCode: UInt16 = 49
    var control = true
    var shift = true
    var option = false
    var command = false
    var label: String { keyCode == 54 && command ? "Right Command" : "\(control ? "Control + " : "")\(shift ? "Shift + " : "")\(option ? "Option + " : "")\(command ? "Command + " : "")Space" }
    func matches(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.control, .shift, .option, .command])
        var expected: NSEvent.ModifierFlags = []
        if control { expected.insert(.control) }
        if shift { expected.insert(.shift) }
        if option { expected.insert(.option) }
        if command { expected.insert(.command) }
        return event.keyCode == keyCode && flags == expected
    }
}

@MainActor
final class MainWindow: NSWindowController {
    var onSave: ((DictationPreferences, HotkeyState) -> Void)?
    var onInstall: (() -> Void)?
    var onPermissions: (() -> Void)?
    private let speech = NSPopUpButton()
    private let cleanup = NSPopUpButton()
    private let speechDetails = NSTextField(wrappingLabelWithString: "")
    private let cleanupDetails = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "Choose local speech and cleanup models. Install only the ones you want.")
    private let hotkey = NSTextField(labelWithString: "Control + Shift + Space")
    private let history = NSButton(checkboxWithTitle: "Keep a local transcript history", target: nil, action: nil)
    private var preferences = DictationPreferences()
    private var binding = HotkeyState()
    private let installButton = NSButton(title: "Select, Install, and Use", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var changeKeyButton: NSButton!
    private var permissionButton: NSButton!
    private let onboarding: Bool

    init(preferences: DictationPreferences, binding: HotkeyState, onboarding: Bool) {
        self.preferences = preferences
        self.binding = binding
        self.onboarding = onboarding
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 600))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.075, alpha: 1).cgColor
        let title = NSTextField(labelWithString: "Fispr Wlow")
        title.font = .systemFont(ofSize: 30, weight: .semibold)
        title.textColor = .white
        title.frame = NSRect(x: 28, y: 544, width: 500, height: 38)
        root.addSubview(title)
        let subtitle = NSTextField(wrappingLabelWithString: "Dictate into the app you choose. Speech and cleanup stay on this Mac.")
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 30, y: 507, width: 500, height: 30)
        root.addSubview(subtitle)

        Self.addLabel("Speech model", y: 468, to: root)
        for model in SpeechModel.allCases { speech.addItem(withTitle: model.name); speech.lastItem?.representedObject = model.rawValue }
        speech.selectItem(at: SpeechModel.allCases.firstIndex(of: preferences.speechModel) ?? 0)
        speech.frame = NSRect(x: 28, y: 424, width: 504, height: 30)
        root.addSubview(speech)
        speechDetails.textColor = .secondaryLabelColor
        speechDetails.font = .systemFont(ofSize: 12.5)
        speechDetails.frame = NSRect(x: 30, y: 389, width: 500, height: 30)
        root.addSubview(speechDetails)

        Self.addLabel("Cleanup model", y: 354, to: root)
        for model in CleanupModel.allCases { cleanup.addItem(withTitle: model.name); cleanup.lastItem?.representedObject = model.rawValue }
        cleanup.selectItem(at: CleanupModel.allCases.firstIndex(of: preferences.cleanupModel) ?? 0)
        cleanup.frame = NSRect(x: 28, y: 310, width: 504, height: 30)
        root.addSubview(cleanup)
        cleanupDetails.textColor = .secondaryLabelColor
        cleanupDetails.font = .systemFont(ofSize: 12.5)
        cleanupDetails.frame = NSRect(x: 30, y: 275, width: 500, height: 30)
        root.addSubview(cleanupDetails)

        Self.addLabel("Hold-to-talk shortcut", y: 234, to: root)
        hotkey.stringValue = binding.label
        hotkey.frame = NSRect(x: 30, y: 200, width: 300, height: 25)
        root.addSubview(hotkey)
        changeKeyButton = NSButton(title: "Change shortcut…", target: nil, action: nil)
        changeKeyButton.frame = NSRect(x: 355, y: 196, width: 176, height: 30)
        root.addSubview(changeKeyButton)
        history.state = preferences.keepHistory ? .on : .off
        history.frame = NSRect(x: 28, y: 160, width: 500, height: 25)
        root.addSubview(history)
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 30, y: 98, width: 500, height: 52)
        root.addSubview(status)
        installButton.frame = NSRect(x: 28, y: 54, width: 388, height: 38)
        installButton.bezelStyle = .rounded
        installButton.keyEquivalent = "\r"
        root.addSubview(installButton)
        cancelButton.frame = NSRect(x: 424, y: 54, width: 108, height: 38)
        cancelButton.bezelStyle = .rounded
        cancelButton.isEnabled = false
        root.addSubview(cancelButton)
        permissionButton = NSButton(title: "Microphone and shortcut permissions…", target: nil, action: nil)
        permissionButton.frame = NSRect(x: 28, y: 14, width: 504, height: 28)
        root.addSubview(permissionButton)
        let window = NSWindow(contentRect: root.bounds, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Fispr Wlow"
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        window.contentView = root
        super.init(window: window)
        speech.target = self; speech.action = #selector(selectionChanged)
        cleanup.target = self; cleanup.action = #selector(selectionChanged)
        changeKeyButton.target = self; changeKeyButton.action = #selector(changeShortcut)
        installButton.target = self; installButton.action = #selector(installSelected)
        cancelButton.target = self; cancelButton.action = #selector(cancelInstall)
        permissionButton.target = self; permissionButton.action = #selector(openPermissions)
        selectionChanged()
    }

    required init?(coder: NSCoder) { nil }

    private static func addLabel(_ text: String, y: CGFloat, to view: NSView) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .white
        label.frame = NSRect(x: 30, y: y, width: 500, height: 23)
        view.addSubview(label)
    }

    @objc private func selectionChanged() {
        guard let s = speech.selectedItem?.representedObject as? String, let speechModel = SpeechModel(rawValue: s),
              let c = cleanup.selectedItem?.representedObject as? String, let cleanupModel = CleanupModel(rawValue: c) else { return }
        preferences.speechModel = speechModel
        preferences.cleanupModel = cleanupModel
        speechDetails.stringValue = speechModel.detail
        cleanupDetails.stringValue = cleanupModel.detail
        let installedSpeech = RuntimeBridge.isInstalled(speechModel)
        let installedCleanup = RuntimeBridge.isInstalled(cleanupModel)
        installButton.title = onboarding || !installedSpeech || !installedCleanup ? "Select, Install, and Use" : "Use These Models"
        if speechModel == .apple {
            status.stringValue = "Apple Speech will run only when macOS says on-device recognition is available. It will never switch to network speech."
        } else if installedSpeech && installedCleanup {
            status.stringValue = "Selected models are installed. Their files stay in this account's Application Support folder."
        } else {
            status.stringValue = "Model files download only after you select this action. No Hugging Face account or token is used."
        }
    }

    @objc private func changeShortcut() {
        let alert = NSAlert()
        alert.messageText = "Choose a hold-to-talk shortcut"
        alert.informativeText = "This version supports Control + Shift + Space, Control + Option + Space, or Right Command."
        alert.addButton(withTitle: "Control + Shift + Space")
        alert.addButton(withTitle: "Control + Option + Space")
        alert.addButton(withTitle: "Right Command")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: binding = HotkeyState(keyCode: 49, control: true, shift: true, option: false, command: false)
        case .alertSecondButtonReturn: binding = HotkeyState(keyCode: 49, control: true, shift: false, option: true, command: false)
        case .alertThirdButtonReturn: binding = HotkeyState(keyCode: 54, control: false, shift: false, option: false, command: true)
        default: return
        }
        hotkey.stringValue = binding.label
    }

    @objc private func installSelected() {
        guard let s = speech.selectedItem?.representedObject as? String, let speechModel = SpeechModel(rawValue: s),
              let c = cleanup.selectedItem?.representedObject as? String, let cleanupModel = CleanupModel(rawValue: c) else { return }
        preferences.speechModel = speechModel
        preferences.cleanupModel = cleanupModel
        preferences.keepHistory = history.state == .on
        status.stringValue = "Preparing selected models…"
        installButton.isEnabled = false
        cancelButton.isEnabled = true
        RuntimeBridge.install(speech: speechModel, cleanup: cleanupModel, progress: { [weak self] line in
            Task { @MainActor in self?.status.stringValue = line }
        }) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.installButton.isEnabled = true
                self.cancelButton.isEnabled = false
                switch result {
                case .success:
                    self.status.stringValue = "Ready. Audio and text stay on this Mac. Hold \(self.binding.label) in any app to dictate."
                    self.onSave?(self.preferences, self.binding)
                case .failure(let error):
                    self.status.stringValue = "\(error.localizedDescription) You can retry or choose another model."
                }
                self.selectionChangedAfterInstall()
            }
        }
    }

    @objc private func cancelInstall() {
        status.stringValue = "Cancelling. You can retry; completed downloads stay available."
        cancelButton.isEnabled = false
        RuntimeBridge.cancelInstall()
    }

    private func selectionChangedAfterInstall() {
        let prior = status.stringValue
        selectionChanged()
        status.stringValue = prior
    }

    @objc private func openPermissions() { onPermissions?() }

    func showStatus(_ text: String) { status.stringValue = text }

    func savedValues() -> (DictationPreferences, HotkeyState) {
        preferences.keepHistory = history.state == .on
        return (preferences, binding)
    }
}

@MainActor
final class ResultWindow: NSWindowController {
    var onInsert: ((String) -> Void)?
    private let raw = NSTextView(frame: NSRect(x: 0, y: 0, width: 288, height: 288))
    private let cleaned = NSTextView(frame: NSRect(x: 0, y: 0, width: 288, height: 288))
    private let status = NSTextField(wrappingLabelWithString: "Review the words before inserting them.")
    private let insertClean = NSButton(title: "Insert cleaned text", target: nil, action: nil)
    private var rawText = ""
    private var cleanText: String?

    init(rawText: String, cleanedText: String?, warning: String? = nil) {
        self.rawText = rawText
        self.cleanText = cleanedText
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 490))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor
        let title = NSTextField(labelWithString: "Review dictation")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.textColor = .white
        title.frame = NSRect(x: 24, y: 448, width: 590, height: 30)
        root.addSubview(title)
        let rawTitle = NSTextField(labelWithString: "Speech result")
        rawTitle.frame = NSRect(x: 24, y: 414, width: 280, height: 20)
        root.addSubview(rawTitle)
        let cleanTitle = NSTextField(labelWithString: "Cleaned text")
        cleanTitle.frame = NSRect(x: 326, y: 414, width: 280, height: 20)
        root.addSubview(cleanTitle)
        raw.string = rawText; raw.isEditable = true; raw.font = .systemFont(ofSize: 14)
        cleaned.string = cleanedText ?? "Cleanup is off or did not finish. Use the speech result on the left."; cleaned.isEditable = true; cleaned.font = .systemFont(ofSize: 14)
        Self.addScroll(raw, frame: NSRect(x: 24, y: 116, width: 288, height: 288), to: root)
        Self.addScroll(cleaned, frame: NSRect(x: 326, y: 116, width: 288, height: 288), to: root)
        status.stringValue = warning ?? "Check names and numbers. Nothing is inserted until you choose a button."
        status.textColor = warning == nil ? .secondaryLabelColor : .systemOrange
        status.frame = NSRect(x: 26, y: 68, width: 590, height: 38)
        root.addSubview(status)
        let insertRaw = NSButton(title: "Insert speech result", target: nil, action: nil)
        insertRaw.frame = NSRect(x: 24, y: 20, width: 278, height: 36)
        root.addSubview(insertRaw)
        insertClean.frame = NSRect(x: 326, y: 20, width: 288, height: 36)
        insertClean.isEnabled = cleanedText != nil
        root.addSubview(insertClean)
        let window = NSWindow(contentRect: root.bounds, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Fispr Wlow"
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = root
        window.center()
        super.init(window: window)
        insertRaw.target = self; insertRaw.action = #selector(insertOriginal)
        insertClean.target = self; insertClean.action = #selector(insertFormatted)
    }

    required init?(coder: NSCoder) { nil }

    private static func addScroll(_ text: NSTextView, frame: NSRect, to view: NSView) {
        let scroll = NSScrollView(frame: frame)
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = text
        text.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1)
        text.textColor = .white
        view.addSubview(scroll)
    }

    @objc private func insertOriginal() { onInsert?(raw.string) }
    @objc private func insertFormatted() { if cleanText != nil { onInsert?(cleaned.string) } }
    func showNotice(_ text: String) { status.stringValue = text }
}

@MainActor
final class FisprApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: MainWindow?
    private var resultWindow: ResultWindow?
    private let capture = DictationCapture()
    private var preferences = DictationPreferences()
    private var binding = HotkeyState()
    private var monitors: [Any] = []
    private var held = false
    private var captureActive = false
    private var focusedTarget: FocusedEditTarget?
    private var latestPartial = ""
    private var sessions = SessionGate()
    private var activeSessionID: UInt64?
    private var captureSpeechModel: SpeechModel = .apple
    private var captureCleanupModel: CleanupModel = .off

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadPreferences()
        NSApp.setActivationPolicy(.accessory)
        capture.onPartial = { [weak self] sessionID, text in
            Task { @MainActor in
                guard let self, self.isCurrentSession(sessionID) else { return }
                self.latestPartial = text
                self.statusItem.button?.toolTip = text
            }
        }
        capture.onLimit = { [weak self] sessionID in
            Task { @MainActor in
                guard let self, self.isCurrentSession(sessionID) else { return }
                self.statusItem.button?.toolTip = "90 second limit reached"
            }
        }
        capture.onSpeechResult = { [weak self] sessionID, result in
            Task { @MainActor in self?.receivedSpeech(result, sessionID: sessionID) }
        }
        buildMenu()
        installMonitors()
        if !UserDefaults.standard.bool(forKey: "configured") { openSettings(onboarding: true) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitors.forEach(NSEvent.removeMonitor)
        invalidateSession()
        RuntimeBridge.terminateActiveProcessAndWait()
    }

    private func loadPreferences() {
        if let data = UserDefaults.standard.data(forKey: "preferences"), let stored = try? JSONDecoder().decode(DictationPreferences.self, from: data) { preferences = stored }
        if let data = UserDefaults.standard.data(forKey: "hotkey"), let stored = try? JSONDecoder().decode(HotkeyState.self, from: data) { binding = stored }
    }

    private func savePreferences(_ values: DictationPreferences, _ key: HotkeyState) {
        invalidateSession()
        preferences = values
        binding = key
        if !values.keepHistory { UserDefaults.standard.removeObject(forKey: "history") }
        UserDefaults.standard.set(try? JSONEncoder().encode(values), forKey: "preferences")
        UserDefaults.standard.set(try? JSONEncoder().encode(key), forKey: "hotkey")
        UserDefaults.standard.set(true, forKey: "configured")
        rebuildMenu()
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = "fw"
        statusItem.button?.toolTip = "Fispr Wlow"
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        let tip = NSMenuItem(title: "Hold \(binding.label) to dictate", action: nil, keyEquivalent: "")
        tip.isEnabled = false
        menu.addItem(tip)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsMenu), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit Fispr Wlow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func installMonitors() {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged], handler: { [weak self] event in
            Task { @MainActor in self?.handleHotkey(event) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged], handler: { [weak self] event in
            Task { @MainActor in self?.handleHotkey(event) }
            return event
        }) { monitors.append(local) }
    }

    private func handleHotkey(_ event: NSEvent) {
        if binding.keyCode == 54 {
            guard event.type == .flagsChanged && event.keyCode == 54 else { return }
            if event.modifierFlags.contains(.command) { startHolding() }
            else { endHolding() }
            return
        }
        if event.type == .keyUp && event.keyCode == binding.keyCode {
            endHolding()
            return
        }
        guard binding.matches(event) else { return }
        if event.type == .keyDown {
            guard !event.isARepeat else { return }
            startHolding()
        }
    }

    private func startHolding() {
        guard !held else { return }
        if let previous = activeSessionID { RuntimeBridge.cancelSession(previous) }
        if captureActive { captureActive = false; capture.cancel() }
        focusedTarget = nil
        let sessionID = sessions.begin()
        activeSessionID = sessionID
        RuntimeBridge.activateSession(sessionID)
        captureSpeechModel = preferences.speechModel
        captureCleanupModel = preferences.cleanupModel
        held = true
        beginWhenAuthorized(sessionID: sessionID, model: captureSpeechModel)
    }

    private func endHolding() {
        held = false
        if captureActive {
            captureActive = false
            statusItem.button?.title = "fw"
            capture.stopAndTranscribe()
        } else if let sessionID = activeSessionID {
            invalidateSession(matching: sessionID)
        }
    }

    private func beginWhenAuthorized(sessionID: UInt64, model: SpeechModel) {
        guard !captureActive else { return }
        guard AXIsProcessTrusted() else {
            openSettings(onboarding: false, notice: "Allow Accessibility in System Settings to use the global shortcut. No audio has been recorded.")
            return
        }
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let continueCapture = { [weak self] in
            Task { @MainActor in
                guard let self, self.held, self.isCurrentSession(sessionID) else { return }
                guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                      model != .apple || SFSpeechRecognizer.authorizationStatus() == .authorized else {
                    self.openSettings(onboarding: false, notice: "\(CaptureError.permissions.localizedDescription) No audio has been recorded.")
                    return
                }
                do {
                    if let processID = NSWorkspace.shared.frontmostApplication?.processIdentifier {
                        self.focusedTarget = FocusedEditTarget.capture(processID: processID)
                    } else { self.focusedTarget = nil }
                    try self.capture.start(model: model, sessionID: sessionID)
                    self.captureActive = true
                    self.statusItem.button?.title = "●"
                    self.statusItem.button?.toolTip = "Listening on this Mac. Release the shortcut to finish."
                } catch {
                    self.capture.cancel()
                    self.invalidateSession(matching: sessionID)
                    self.settingsWindow?.showStatus(error.localizedDescription)
                    self.statusItem.button?.toolTip = error.localizedDescription
                }
            }
        }
        func requestMic() {
            if micStatus == .notDetermined { AVCaptureDevice.requestAccess(for: .audio) { _ in _ = continueCapture() } }
            else { _ = continueCapture() }
        }
        if model == .apple && speechStatus == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { _ in requestMic() }
        } else { requestMic() }
    }

    private func isCurrentSession(_ sessionID: UInt64) -> Bool {
        sessions.accepts(sessionID) && activeSessionID == sessionID
    }

    private func invalidateSession(matching sessionID: UInt64? = nil) {
        if let sessionID, activeSessionID != sessionID { return }
        let oldSession = activeSessionID
        sessions.invalidate()
        activeSessionID = nil
        held = false
        focusedTarget = nil
        if captureActive { captureActive = false }
        capture.cancel()
        if let oldSession { RuntimeBridge.cancelSession(oldSession) }
        statusItem?.button?.title = "fw"
    }

    private func receivedSpeech(_ result: Result<String, Error>, sessionID: UInt64) {
        guard isCurrentSession(sessionID) else { return }
        switch result {
        case .failure(let error):
            invalidateSession(matching: sessionID)
            statusItem.button?.toolTip = error.localizedDescription
        case .success(let transcript):
            let raw = String(transcript.prefix(12_000)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else {
                invalidateSession(matching: sessionID)
                statusItem.button?.toolTip = CaptureError.noSpeech.localizedDescription
                return
            }
            guard captureCleanupModel != .off, RuntimeBridge.isInstalled(captureCleanupModel) else {
                showReview(raw: raw, cleaned: nil, sessionID: sessionID)
                return
            }
            statusItem.button?.toolTip = "Cleaning text locally…"
            RuntimeBridge.clean(raw, model: captureCleanupModel, sessionID: sessionID) { [weak self] result in
                Task { @MainActor in
                    guard let self, self.isCurrentSession(sessionID) else { return }
                    switch result {
                    case .failure(let error):
                        self.showReview(raw: raw, cleaned: nil, warning: "Cleanup failed: \(error.localizedDescription) The speech result is unchanged.", sessionID: sessionID)
                    case .success(let clean):
                        if FactsPreserver.protectedTokens(raw) == FactsPreserver.protectedTokens(clean) {
                            self.showReview(raw: raw, cleaned: clean, sessionID: sessionID)
                        } else {
                            self.showReview(raw: raw, cleaned: nil, warning: "Cleanup changed a name or number. The speech result is shown unchanged.", sessionID: sessionID)
                        }
                    }
                }
            }
        }
    }

    private func showReview(raw: String, cleaned: String?, warning: String? = nil, sessionID: UInt64) {
        guard isCurrentSession(sessionID) else { return }
        sessions.invalidate()
        activeSessionID = nil
        let window = ResultWindow(rawText: raw, cleanedText: cleaned, warning: warning)
        window.onInsert = { [weak self] text in self?.insert(text) }
        resultWindow = window
        window.showWindow(nil)
        if preferences.keepHistory { saveHistory(raw) }
        statusItem.button?.toolTip = "Dictation is ready for review."
    }

    private func insert(_ text: String) {
        guard let target = focusedTarget, let app = NSRunningApplication(processIdentifier: target.processID), !text.isEmpty else {
            resultWindow?.showNotice("No safe text field was focused when dictation started. Select and copy text from Review instead.")
            return
        }
        app.activate(options: [.activateAllWindows])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard target.isStillFocused() else {
                self?.resultWindow?.showNotice("The original text field or selection changed. Text was not inserted.")
                return
            }
            if target.insertWithAccessibility(text) {
                self?.resultWindow?.close()
                return
            }
            let pasteboard = NSPasteboard.general
            guard target.isStillFocused(), let snapshot = PasteboardSnapshot.capture(pasteboard) else {
                self?.resultWindow?.showNotice("The original text field changed or the clipboard could not be preserved. Text was not inserted.")
                return
            }
            guard pasteboard.changeCount == snapshot.changeCount else {
                self?.resultWindow?.showNotice("The clipboard changed. Text was not inserted.")
                return
            }
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else {
                _ = snapshot.restore(pasteboard)
                self?.resultWindow?.showNotice("The clipboard could not be prepared. Text was not inserted.")
                return
            }
            let insertedClipboardChange = pasteboard.changeCount
            guard target.isStillFocused(), pasteboard.changeCount == insertedClipboardChange else {
                if pasteboard.changeCount == insertedClipboardChange { _ = snapshot.restore(pasteboard) }
                self?.resultWindow?.showNotice("The original text field or clipboard changed. Text was not inserted.")
                return
            }
            let source = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
            guard let down, let up else {
                if pasteboard.changeCount == insertedClipboardChange { _ = snapshot.restore(pasteboard) }
                self?.resultWindow?.showNotice("The paste shortcut could not be sent. Text was not inserted.")
                return
            }
            down.flags = .maskCommand
            up.flags = .maskCommand
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard pasteboard.changeCount == insertedClipboardChange else { return }
                _ = snapshot.restore(pasteboard)
            }
            self?.resultWindow?.close()
        }
    }

    private func saveHistory(_ text: String) {
        var history = UserDefaults.standard.stringArray(forKey: "history") ?? []
        history.append(text)
        UserDefaults.standard.set(Array(history.suffix(100)), forKey: "history")
    }

    @objc private func openSettingsMenu() { openSettings(onboarding: false) }

    private func openSettings(onboarding: Bool, notice: String? = nil) {
        invalidateSession()
        let values = settingsWindow?.savedValues() ?? (preferences, binding)
        let window = MainWindow(preferences: values.0, binding: values.1, onboarding: onboarding)
        if let notice { window.showStatus(notice) }
        window.onSave = { [weak self] preferences, key in self?.savePreferences(preferences, key) }
        window.onPermissions = { [weak self] in self?.openPrivacySettings() }
        settingsWindow = window
        window.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openPrivacySettings() {
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            return
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }
}

enum FactsPreserver {
    static func protectedTokens(_ text: String) -> [String] {
        let pattern = #"\b[\p{L}\p{N}]+(?:['’\-][\p{L}\p{N}]+)*\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var protected: [String] = []
        var previousEnd = text.startIndex
        var sentenceStart = true
        for match in regex.matches(in: text, range: range) {
            guard let tokenRange = Range(match.range, in: text) else { continue }
            let gap = text[previousEnd..<tokenRange.lowerBound]
            if gap.contains(where: { ".!?\n".contains($0) }) { sentenceStart = true }
            let token = String(text[tokenRange])
            let containsNumber = token.contains(where: { $0.isNumber })
            let letters = token.filter(\.isLetter)
            let uppercase = letters.allSatisfy(\.isUppercase) && letters.count > 1
            let capitalizedName = letters.first?.isUppercase == true && !sentenceStart
            if containsNumber || uppercase || capitalizedName { protected.append(token.lowercased()) }
            sentenceStart = false
            previousEnd = tokenRange.upperBound
        }
        return protected.sorted()
    }
}

#if !FISPR_TEST
@main
enum FisprWlowMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = FisprApp()
        app.delegate = delegate
        app.run()
    }
}
#endif
