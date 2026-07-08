import AgentSyncCore
import AppKit
import Foundation

/// macOS has no "default terminal" registry (nothing like the default-browser
/// LaunchServices API), so this is a curated set of known terminals, shown in
/// Settings only when installed and each launched the way it natively supports.
enum TerminalApp: String, CaseIterable, Identifiable {
    case terminal
    case iterm
    case ghostty
    case cmux

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .terminal:
            return "Terminal"
        case .iterm:
            return "iTerm2"
        case .ghostty:
            return "Ghostty"
        case .cmux:
            return "CMUX"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .terminal:
            return "com.apple.Terminal"
        case .iterm:
            return "com.googlecode.iterm2"
        case .ghostty:
            return "com.mitchellh.ghostty"
        case .cmux:
            return "com.cmuxterm.app"
        }
    }

    var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    var isInstalled: Bool {
        appURL != nil
    }

    static var installed: [TerminalApp] {
        allCases.filter(\.isInstalled)
    }
}

enum TerminalLaunchError: LocalizedError {
    case launchFailed(String, Int32, String)
    case notInstalled(String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let terminal, let status, let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(terminal) launch failed (status \(status))\(trimmed.isEmpty ? "" : ": \(trimmed)")"
        case .notInstalled(let terminal):
            return "\(terminal) is not installed."
        }
    }
}

enum TerminalLauncher {
    static func launch(_ ticket: ResumeTicket, using preferred: TerminalApp) throws {
        let terminal = preferred.isInstalled ? preferred : .terminal
        let cwd = existingDirectoryOrHome(ticket.workingDirectory)
        let command = resumeCommand(for: ticket, cwd: cwd, includeCD: terminal != .cmux)

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
            // Ghostty is not scriptable; its macOS binary accepts -e like the
            // Linux one. `open -n` spawns a new window running the command.
            try run(
                "/usr/bin/open",
                arguments: ["-na", appURL.path, "--args", "-e", "/bin/zsh", "-ilc", command],
                terminal: terminal
            )
        case .cmux:
            try launchCMUX(ticket: ticket, cwd: cwd, command: command)
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
            // A configured resume model is the only way to make OpenCode run a
            // specific model — it ignores models stamped on imported messages.
            let configured = Prefs.opencodeResumeModel
            if !configured.isEmpty {
                launch += " -m \(shellQuote(configured))"
            }
            run = launch
        }
        return includeCD ? "cd \(shellQuote(cwd)) && \(run)" : run
    }

    private static func launchCMUX(ticket: ResumeTicket, cwd: String, command: String) throws {
        guard let appURL = TerminalApp.cmux.appURL else {
            throw TerminalLaunchError.notInstalled(TerminalApp.cmux.displayName)
        }
        let cli = appURL.appendingPathComponent("Contents/Resources/bin/cmux").path
        let workspaceName = "\(ticket.targetProvider.displayName): \(URL(fileURLWithPath: cwd).lastPathComponent)"
        var arguments = [
            "workspace", "create",
            "--name", workspaceName,
            "--cwd", cwd,
            "--command", command
        ]
        // CMUX's socket only trusts cmux-descended processes unless password
        // auth is configured; pass the configured password explicitly.
        if let password = cmuxSocketPassword() {
            arguments = ["--password", password] + arguments
        }

        do {
            try run(cli, arguments: arguments, terminal: .cmux)
            NSWorkspace.shared.open(appURL)
        } catch {
            // Maybe the app isn't running: start it and retry briefly.
            NSWorkspace.shared.open(appURL)
            for _ in 0..<6 {
                Thread.sleep(forTimeInterval: 0.5)
                if (try? run(cli, arguments: arguments, terminal: .cmux)) != nil {
                    return
                }
            }
            // CMUX unreachable (e.g. socket in cmuxOnly mode until its next
            // restart) — fall back to Terminal rather than failing the resume.
            try launchWithTerminalApp(command: resumeCommand(for: ticket, cwd: cwd, includeCD: true))
        }
    }

    private static func cmuxSocketPassword() -> String? {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cmux/cmux.json")
        guard let text = try? String(contentsOf: configURL, encoding: .utf8),
              let match = text.range(
                  of: #""socketPassword"\s*:\s*"([^"]+)""#,
                  options: .regularExpression
              ) else {
            return nil
        }
        let fragment = String(text[match])
        guard let colon = fragment.range(of: ":") else {
            return nil
        }
        return fragment[colon.upperBound...]
            .trimmingCharacters(in: CharacterSet(charactersIn: " \""))
    }

    private static func launchWithTerminalApp(command: String) throws {
        try runAppleScript("""
        tell application "Terminal"
            activate
            do script "\(appleScriptEscaped(command))"
        end tell
        """, terminal: .terminal)
    }

    private static func runAppleScript(_ script: String, terminal: TerminalApp) throws {
        try run("/usr/bin/osascript", arguments: ["-e", script], terminal: terminal)
    }

    private static func run(_ executable: String, arguments: [String], terminal: TerminalApp) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // App-spawned processes get a bare PATH; CLIs that shell out to
        // helpers (cmux, opencode) need a real one.
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = "\(home)/.local/bin:\(home)/.opencode/bin:/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["CMUX_QUIET"] = "1"
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // Drain both before waiting to avoid pipe deadlocks.
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
        if FileManager.default.isExecutableFile(atPath: local) {
            return local
        }
        return "claude"
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
