import Darwin
import Foundation

enum CMUXConnectionStatus: Equatable, Sendable {
    case ready
    case passwordMissing
    case restricted
    case disabled

    var isReady: Bool {
        self == .ready
    }

    var title: String {
        switch self {
        case .ready:
            return "CMUX connected"
        case .passwordMissing, .restricted, .disabled:
            return "CMUX needs setup"
        }
    }

    var guidance: String? {
        switch self {
        case .ready:
            return nil
        case .passwordMissing:
            return "Set a password in CMUX Settings → Automation."
        case .restricted:
            return "Choose Password access in CMUX Settings → Automation, then set a password."
        case .disabled:
            return "Turn on Password access in CMUX Settings → Automation, then set a password."
        }
    }
}

enum CMUXIntegration {
    private enum SocketMode {
        case off
        case restricted
        case password
        case allowAll
    }

    static func connectionStatus(
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CMUXConnectionStatus {
        switch socketMode(fileManager: fileManager, homeDirectory: homeDirectory) {
        case .off:
            return .disabled
        case .restricted:
            return .restricted
        case .allowAll:
            return .ready
        case .password:
            return socketPassword(
                fileManager: fileManager,
                homeDirectory: homeDirectory,
                environment: environment
            ) == nil ? .passwordMissing : .ready
        }
    }

    /// CMUX keeps its current password in an owner-only state file so its app
    /// and separately signed CLI can share it without a macOS App Data prompt.
    /// Older CMUX builds used Application Support or a plaintext config key;
    /// keep those locations as read-only fallbacks for existing users.
    static func socketPassword(
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let password = normalized(environment["CMUX_SOCKET_PASSWORD"]) {
            return password
        }

        let home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/state/cmux/socket-control-password"),
            home.appendingPathComponent(".config/cmux/socket-control-password"),
            home.appendingPathComponent("Library/Application Support/cmux/socket-control-password")
        ]
        for url in candidates {
            if let password = try? String(contentsOf: url, encoding: .utf8),
               let normalized = normalized(password) {
                return normalized
            }
        }

        for url in configURLs(homeDirectory: home) {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let password = captureValue(named: "socketPassword", in: text),
                  let normalized = normalized(password) else {
                continue
            }
            return normalized
        }
        return nil
    }

    static func socketPath(
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let override = normalized(environment["CMUX_SOCKET_PATH"]) {
            return override
        }
        let home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        let stateDirectory = home.appendingPathComponent(".local/state/cmux", isDirectory: true)
        let marker = stateDirectory.appendingPathComponent("last-socket-path")
        if let markedPath = try? String(contentsOf: marker, encoding: .utf8),
           let normalized = normalized(markedPath),
           fileManager.fileExists(atPath: normalized) {
            return normalized
        }
        let candidates = [
            stateDirectory.appendingPathComponent("cmux.sock").path,
            stateDirectory.appendingPathComponent("cmux-\(getuid()).sock").path,
            "/tmp/cmux.sock"
        ]
        return candidates.first(where: fileManager.fileExists(atPath:)) ?? candidates[0]
    }

    private static func socketMode(
        fileManager: FileManager,
        homeDirectory: URL?
    ) -> SocketMode {
        let home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        for url in configURLs(homeDirectory: home) {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let rawMode = captureValue(named: "socketControlMode", in: text) else {
                continue
            }
            let normalized = rawMode
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "-", with: "")
            switch normalized {
            case "off":
                return .off
            case "password":
                return .password
            case "allowall", "openaccess", "fullopenaccess", "full":
                return .allowAll
            default:
                return .restricted
            }
        }
        // CMUX defaults to accepting only its own descendants. Continuo is an
        // external app, so an absent setting still needs explicit setup.
        return .restricted
    }

    private static func configURLs(homeDirectory: URL) -> [URL] {
        [
            homeDirectory.appendingPathComponent(".config/cmux/cmux.json"),
            homeDirectory.appendingPathComponent(".config/cmux/settings.json"),
            homeDirectory.appendingPathComponent("Library/Application Support/com.cmuxterm.app/settings.json")
        ]
    }

    private static func captureValue(named key: String, in text: String) -> String? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let pattern = "\\\"" + escapedKey + "\\\"\\s*:\\s*\\\"([^\\\"]*)\\\""
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
