import AgentSyncCore
import AppKit
import SwiftUI

/// Dev-only screenshot generator for the README. Runs when the app is launched
/// with `CONTINUO_SHOTS=<output-dir>`; it injects fabricated sessions into a
/// demo model that never scans your real homes, shows the real views in real
/// windows, captures each, and exits. Not part of the normal app flow.
@MainActor
enum Screenshots {
    private static var outputDir = URL(fileURLWithPath: "/tmp")
    private static let model = AppModel(demo: true)

    struct Job {
        let name: String
        let width: CGFloat
        let view: AnyView
    }

    static func generate(into directory: URL) {
        outputDir = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let empty = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("continuo-shots-empty", isDirectory: true)
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        ModelCatalog.configure(stateDirectory: empty)

        // Settings shows the real default paths; the picker/continue don't show
        // paths, so these defaults are only visible in the settings shot.
        UserDefaults.standard.set("~/.claude", forKey: Prefs.claudeHomeKey)
        UserDefaults.standard.set("~/.codex", forKey: Prefs.codexHomeKey)
        UserDefaults.standard.set("~/.local/share/opencode", forKey: Prefs.opencodeHomeKey)
        UserDefaults.standard.set("~/Library/Application Support/AgentSync", forKey: Prefs.stateDirectoryKey)

        model.sessions = demoSessions()
        model.observedModels = [
            .claude: ["claude-opus-4-8", "claude-sonnet-5", "claude-haiku-4-5"],
            .codex: ["gpt-5.5", "gpt-5.1-codex", "gpt-5.1-codex-mini"]
        ]

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let jobs = [
            Job(name: "picker", width: 480, view: AnyView(SessionPickerView(model: model))),
            Job(name: "continue", width: 480, view: AnyView(ContinueView(model: model, item: demoSessions()[0], onDismiss: {}))),
            Job(name: "settings", width: 600, view: AnyView(SettingsView(model: model)))
        ]
        run(jobs, index: 0)
    }

    private static func run(_ jobs: [Job], index: Int) {
        guard index < jobs.count else {
            exit(0)
        }
        let job = jobs[index]
        let hosting = NSHostingController(rootView: job.view)
        hosting.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.setContentSize(NSSize(width: job.width, height: 560))
        window.center()
        window.makeKeyAndOrderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if let image = CGWindowListCreateImage(
                .null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                [.boundsIgnoreFraming, .bestResolution]
            ) {
                let rep = NSBitmapImageRep(cgImage: image)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: outputDir.appendingPathComponent("\(job.name).png"))
                }
            }
            window.orderOut(nil)
            run(jobs, index: index + 1)
        }
    }

    private static func demoSessions() -> [SessionItem] {
        let now = Date()
        func session(_ provider: AgentKind, _ title: String, _ repo: String, _ tokens: Int, _ ago: TimeInterval, _ models: [String], origin: AgentKind? = nil) -> SessionItem {
            let preview = SessionPreview(
                provider: provider,
                sessionID: repo + title,
                path: "/Users/you/Developer/\(repo)/session.jsonl",
                title: title,
                snippet: title,
                models: models,
                estimatedTokens: tokens,
                cwd: "/Users/you/Developer/\(repo)",
                updatedAt: now.addingTimeInterval(-ago)
            )
            return SessionItem(preview: preview, mirrorOrigin: origin, refinedTitle: nil)
        }
        return [
            session(.claude, "Add cursor-based pagination to the feed API", "photon-api", 96_000, 8 * 60, ["claude-opus-4-8"]),
            session(.codex, "Track down the websocket reconnect loop", "chat-service", 142_000, 42 * 60, ["gpt-5.5"]),
            session(.opencode, "Migrate the config loader to TOML", "infra-cli", 51_000, 2 * 3600, ["anthropic/claude-sonnet-5"]),
            session(.claude, "Write integration tests for the auth flow", "acme-web", 73_000, 5 * 3600, ["claude-sonnet-5"], origin: .codex),
            session(.codex, "Refactor payment retry backoff", "billing", 210_000, 26 * 3600, ["gpt-5.1-codex"]),
            session(.claude, "Set up ESLint and Prettier across the monorepo", "monorepo", 38_000, 27 * 3600, ["claude-haiku-4-5"])
        ]
    }
}
