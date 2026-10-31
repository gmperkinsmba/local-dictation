import Foundation

enum SpeechModel: String, CaseIterable, Identifiable, Codable {
    case apple = "apple-on-device"
    case whisperTiny = "whisper-tiny-en"
    case whisperBase = "whisper-base-en"
    case whisperTurbo = "whisper-large-v3-turbo"

    var id: String { rawValue }
    var name: String {
        switch self {
        case .apple: "Apple Speech"
        case .whisperTiny: "Whisper Tiny English"
        case .whisperBase: "Whisper Base English"
        case .whisperTurbo: "Whisper Large v3 Turbo"
        }
    }
    var detail: String {
        switch self {
        case .apple: "Built into macOS. Speed and memory are managed by the OS; no download. On-device English support varies."
        case .whisperTiny: "Fastest Whisper choice. About 51 MB model files; runtime also downloads a 139 MB PyTorch wheel. Allow about 0.5 GB of memory."
        case .whisperBase: "More speech detail. About 81 MB model files; runtime also downloads a 139 MB PyTorch wheel. Allow about 0.8 GB of memory."
        case .whisperTurbo: "Best of these Whisper choices. About 1.6 GB model files; runtime also downloads a 139 MB PyTorch wheel. Allow about 4 GB of memory."
        }
    }
    var repo: String? {
        switch self {
        case .apple: nil
        case .whisperTiny: "mlx-community/whisper-tiny.en-mlx-4bit"
        case .whisperBase: "mlx-community/whisper-base.en-mlx-q4"
        case .whisperTurbo: "mlx-community/whisper-large-v3-turbo"
        }
    }
    var revision: String? {
        switch self {
        case .apple: nil
        case .whisperTiny: "29d36db3e9797dd67b210d0ab965522035f82a8b"
        case .whisperBase: "05ab7e95b795f9a4921b51a9573e7c9ffe506ae4"
        case .whisperTurbo: "a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb"
        }
    }
}

enum CleanupModel: String, CaseIterable, Identifiable, Codable {
    case off = "off"
    case qwenSmall = "qwen3-0.6b"
    case qwenLarge = "qwen3-1.7b"

    var id: String { rawValue }
    var name: String {
        switch self {
        case .off: "Off"
        case .qwenSmall: "Qwen3 0.6B, 4-bit"
        case .qwenLarge: "Qwen3 1.7B, 4-bit"
        }
    }
    var detail: String {
        switch self {
        case .off: "Keep the speech result as-is. No cleanup model or download."
        case .qwenSmall: "Light punctuation and filler cleanup. 335 MB download; allow about 1.2 GB of memory."
        case .qwenLarge: "Better wording and paragraph breaks. 968 MB download; allow about 2 GB of memory."
        }
    }
    var repo: String? {
        switch self {
        case .off: nil
        case .qwenSmall: "mlx-community/Qwen3-0.6B-4bit"
        case .qwenLarge: "mlx-community/Qwen3-1.7B-4bit"
        }
    }
    var revision: String? {
        switch self {
        case .off: nil
        case .qwenSmall: "73e3e38d981303bc594367cd910ea6eb48349da8"
        case .qwenLarge: "3b1b1768f8f8cf8351c712464f906e86c2b8269e"
        }
    }
}

struct DictationPreferences: Codable, Equatable {
    var speechModel: SpeechModel = .apple
    var cleanupModel: CleanupModel = .off
    var keepHistory = false
}

struct SessionGate {
    private(set) var current: UInt64 = 0
    mutating func begin() -> UInt64 { current &+= 1; return current }
    mutating func invalidate() { current &+= 1 }
    func accepts(_ session: UInt64) -> Bool { session != 0 && session == current }
}

struct HelperStartGate {
    private(set) var isShuttingDown = false
    private(set) var currentSessionID: UInt64 = 0
    private(set) var cancelledSessionID: UInt64?
    private(set) var activeInstallationID: UUID?
    private(set) var cancelledInstallationID: UUID?

    mutating func activateSession(_ sessionID: UInt64) {
        currentSessionID = sessionID
        cancelledSessionID = nil
    }

    mutating func cancelSession(_ sessionID: UInt64) {
        if currentSessionID == sessionID { cancelledSessionID = sessionID }
    }

    mutating func beginInstallation(_ id: UUID) -> Bool {
        guard !isShuttingDown, activeInstallationID == nil else { return false }
        activeInstallationID = id
        cancelledInstallationID = nil
        return true
    }

    mutating func cancelInstallation(_ id: UUID) {
        if activeInstallationID == id { cancelledInstallationID = id }
    }

    mutating func finishInstallation(_ id: UUID) {
        if activeInstallationID == id {
            activeInstallationID = nil
            cancelledInstallationID = nil
        }
    }

    mutating func shutDown() { isShuttingDown = true }

    func canStart(sessionID: UInt64?, installationID: UUID?) -> Bool {
        guard !isShuttingDown else { return false }
        if let sessionID, (sessionID != currentSessionID || sessionID == cancelledSessionID) { return false }
        if let installationID, (installationID != activeInstallationID || installationID == cancelledInstallationID) { return false }
        return true
    }
}

enum ModelCatalog {
    static func installed(_ model: SpeechModel, at root: URL) -> Bool {
        guard let repo = model.repo else { return true }
        let folder = root.appendingPathComponent(repo)
        return ["model.safetensors", "weights.safetensors", "weights.npz"].contains {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }
    static func installed(_ model: CleanupModel, at root: URL) -> Bool {
        guard let repo = model.repo else { return true }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent(repo).appendingPathComponent("model.safetensors").path)
    }
}
