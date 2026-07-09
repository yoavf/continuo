import AgentSyncCore
import AppKit
import Foundation

enum TerminalApp: String, CaseIterable, Identifiable {
    case terminal
    case iterm
    case ghostty
    case cmux
    case superset

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .terminal: return "Terminal"
        case .iterm: return "iTerm2"
        case .ghostty: return "Ghostty"
        case .cmux: return "CMUX"
        case .superset: return "Superset"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .iterm: return "com.googlecode.iterm2"
        case .ghostty: return "com.mitchellh.ghostty"
        case .cmux: return "com.cmuxterm.app"
        case .superset: return "com.superset.desktop"
        }
    }

    var setupInstructions: String {
        switch self {
        case .cmux:
            return "Open CMUX yourself, then choose CMUX → Settings → Automation. Select Password access and set a password before trying again."
        case .superset:
            return "Open Superset and turn on Settings → Experimental → Try Superset v2. Then run ~/.superset/bin/superset auth login in Terminal and return to Continuo."
        case .terminal, .iterm, .ghostty:
            return "Open the terminal once, then try again."
        }
    }

    var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    var isInstalled: Bool { appURL != nil }

    static var installed: [TerminalApp] {
        allCases.filter(\.isInstalled)
    }
}

enum TerminalLaunchError: LocalizedError {
    case launchFailed(String, Int32, String)
    case notInstalled(String)
    case cmuxSetupRequired(CMUXConnectionStatus)
    case supersetSetupRequired(String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let terminal, let status, let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = trimmed.isEmpty ? "" : ": \(trimmed)"
            return "\(terminal) launch failed (status \(status))\(suffix)"
        case .notInstalled(let terminal):
            return "\(terminal) is not installed."
        case .cmuxSetupRequired(let status):
            return status.guidance ?? "CMUX needs setup in Settings → Automation."
        case .supersetSetupRequired(let detail):
            return detail
        }
    }

    var setupAlert: TerminalSetupAlert? {
        switch self {
        case .cmuxSetupRequired:
            return TerminalSetupAlert(
                terminal: .cmux,
                message: errorDescription ?? TerminalApp.cmux.setupInstructions
            )
        case .supersetSetupRequired:
            return TerminalSetupAlert(
                terminal: .superset,
                message: errorDescription ?? TerminalApp.superset.setupInstructions
            )
        case .launchFailed, .notInstalled:
            return nil
        }
    }
}

struct TerminalSetupAlert: Identifiable {
    let terminal: TerminalApp
    let message: String

    var id: String { "\(terminal.rawValue):\(message)" }
}

enum TerminalLaunchPreparation: Sendable {
    case standard
    case superset(workspaceID: String, workingDirectory: String)
}

enum TerminalLauncher {
    static var cmuxConnectionStatus: CMUXConnectionStatus {
        CMUXIntegration.connectionStatus()
    }

    static var supersetConnectionStatus: SupersetConnectionStatus {
        SupersetIntegration.connectionStatus()
    }

    static func preflight(
        _ preferred: TerminalApp,
        workingDirectory: String? = nil
    ) throws -> TerminalLaunchPreparation {
        switch preferred {
        case .cmux:
            guard preferred.isInstalled else {
                throw TerminalLaunchError.notInstalled(preferred.displayName)
            }
            let status = cmuxConnectionStatus
            guard status.isReady else {
                throw TerminalLaunchError.cmuxSetupRequired(status)
            }
        case .superset:
            guard preferred.isInstalled else {
                throw TerminalLaunchError.notInstalled(preferred.displayName)
            }
            guard supersetConnectionStatus.isReady else {
                throw TerminalLaunchError.supersetSetupRequired(
                    supersetConnectionStatus.guidance ?? preferred.setupInstructions
                )
            }
            guard let workingDirectory else {
                return .standard
            }
            do {
                let resolution = try SupersetIntegration.workspace(
                    containing: existingDirectoryOrHome(workingDirectory)
                )
                return .superset(
                    workspaceID: resolution.workspace.id,
                    workingDirectory: resolution.workingDirectory
                )
            } catch {
                throw TerminalLaunchError.supersetSetupRequired(error.localizedDescription)
            }
        case .terminal, .iterm, .ghostty:
            break
        }
        return .standard
    }

}

extension TerminalLauncher {
    static func launch(
        _ ticket: ResumeTicket,
        using preferred: TerminalApp,
        preparation suppliedPreparation: TerminalLaunchPreparation? = nil
    ) throws {
        let terminal = preferred.isInstalled ? preferred : .terminal
        let cwd = existingDirectoryOrHome(ticket.workingDirectory)
        let preparation: TerminalLaunchPreparation
        if let suppliedPreparation {
            preparation = suppliedPreparation
        } else {
            preparation = try preflight(terminal, workingDirectory: cwd)
        }
        let command = resumeCommand(
            for: ticket,
            cwd: cwd,
            includeCD: terminal != .cmux && terminal != .superset
        )

        switch terminal {
        case .terminal:
            try runAppleScript("""
            tell application "Terminal"
                activate
                do script "\(appleScriptEscaped(command))"
            end tell
            """, terminal: terminal)
        case .iterm:
            try runAppleScript("""
            tell application "iTerm"
                activate
                set newWindow to (create window with default profile)
                tell current session of newWindow
                    write text "\(appleScriptEscaped(command))"
                end tell
            end tell
            """, terminal: terminal)
        case .ghostty:
            guard let appURL = terminal.appURL else {
                throw TerminalLaunchError.notInstalled(terminal.displayName)
            }
            try run(
                "/usr/bin/open",
                arguments: ["-na", appURL.path, "--args", "-e", "/bin/zsh", "-ilc", command],
                terminal: terminal
            )
        case .cmux:
            try launchCMUX(ticket: ticket, cwd: cwd, command: command)
        case .superset:
            guard case let .superset(workspaceID, workingDirectory) = preparation else {
                throw TerminalLaunchError.supersetSetupRequired(
                    TerminalApp.superset.setupInstructions
                )
            }
            try launchSuperset(
                workspaceID: workspaceID,
                cwd: workingDirectory,
                command: command
            )
        }
    }

    private static func resumeCommand(for ticket: ResumeTicket, cwd: String, includeCD: Bool) -> String {
        let run: String
        switch ticket.targetProvider {
        case .codex:
            run = "codex resume \(shellQuote(ticket.targetSessionID))"
        case .claude:
            run = "\(shellQuote(claudeExecutable())) --resume \(shellQuote(ticket.targetSessionID))"
        case .opencode:
            let executable = OpenCodeAdapter.executableURL()?.path ?? "opencode"
            var launch = "\(shellQuote(executable)) --session \(shellQuote(ticket.targetSessionID))"
            let configured = Prefs.opencodeResumeModel
            if !configured.isEmpty {
                launch += " -m \(shellQuote(configured))"
            }
            run = launch
        }
        return includeCD ? "cd \(shellQuote(cwd)) && \(run)" : run
    }

    private static func launchCMUX(ticket: ResumeTicket, cwd: String, command: String) throws {
        guard TerminalApp.cmux.isInstalled else {
            throw TerminalLaunchError.notInstalled(TerminalApp.cmux.displayName)
        }
        let workspaceName = "\(ticket.targetProvider.displayName): \(URL(fileURLWithPath: cwd).lastPathComponent)"
        let client = try connectedCMUXClient()
        defer { client.close() }

        let workspace = try client.request(
            method: "workspace.create",
            params: ["title": workspaceName, "cwd": cwd, "focus": true]
        )
        let workspaceID = workspace["workspace_ref"] as? String
            ?? workspace["workspace_id"] as? String
        guard let workspaceID else {
            throw CMUXSocketError.invalidResponse
        }
        try client.request(
            method: "surface.send_text",
            params: ["workspace_id": workspaceID, "text": command + "\n"]
        )
        NSRunningApplication.runningApplications(
            withBundleIdentifier: TerminalApp.cmux.bundleIdentifier
        ).first?.activate(options: [])
    }

    private static func connectedCMUXClient() throws -> CMUXSocketClient {
        let client = CMUXSocketClient(path: CMUXIntegration.socketPath())
        do {
            try client.connect()
            try client.authenticate(password: CMUXIntegration.socketPassword())
            return client
        } catch {
            client.close()
            throw error
        }
    }

    private static func launchSuperset(
        workspaceID: String,
        cwd: String,
        command: String
    ) throws {
        do {
            let terminal = try SupersetIntegration.createTerminal(
                workspaceID: workspaceID,
                workingDirectory: cwd,
                command: command
            )
            let url = try SupersetIntegration.terminalURL(
                workspaceID: workspaceID,
                terminalID: terminal.terminalId
            )
            guard NSWorkspace.shared.open(url) else {
                throw SupersetIntegrationError.openFailed
            }
        } catch {
            throw TerminalLaunchError.supersetSetupRequired(error.localizedDescription)
        }
    }
}

extension TerminalLauncher {
    private static func runAppleScript(_ script: String, terminal: TerminalApp) throws {
        try run("/usr/bin/osascript", arguments: ["-e", script], terminal: terminal)
    }

    private static func run(_ executable: String, arguments: [String], terminal: TerminalApp) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fallbackPath = "/usr/bin:/bin"
        let inheritedPath = environment["PATH"] ?? fallbackPath
        environment["PATH"] = "\(home)/.local/bin:\(home)/.opencode/bin:/opt/homebrew/bin:/usr/local/bin:\(inheritedPath)"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errData + outData, encoding: .utf8) ?? ""
            throw TerminalLaunchError.launchFailed(terminal.displayName, process.terminationStatus, detail)
        }
    }

    private static func existingDirectoryOrHome(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue {
            return expanded
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    private static func claudeExecutable() -> String {
        let local = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/claude")
            .path
        return FileManager.default.isExecutableFile(atPath: local) ? local : "claude"
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
