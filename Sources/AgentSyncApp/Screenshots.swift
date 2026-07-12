import AgentSyncCore
import AppKit
import ScreenCaptureKit
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
        let height: CGFloat?
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
        UserDefaults.standard.set(
            CodexLaunchDestination.chatGPTDesktop.rawValue,
            forKey: Prefs.codexLaunchDestinationKey
        )

        model.sessions = demoSessions()
        model.observedModels = [
            .claude: ["claude-opus-4-8", "claude-sonnet-5", "claude-haiku-4-5"],
            .codex: ["gpt-5.5", "gpt-5.1-codex", "gpt-5.1-codex-mini"]
        ]

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let jobs = [
            Job(name: "picker", width: 480, height: nil, view: AnyView(SessionPickerView(model: model))),
            Job(name: "continue", width: 480, height: nil, view: AnyView(ContinueView(model: model, item: demoSessions()[0], onDismiss: {}))),
            Job(name: "settings", width: 600, height: 620, view: AnyView(SettingsView(model: model)))
        ]
        run(jobs, index: 0)
    }

    private static func run(_ jobs: [Job], index: Int) {
        guard index < jobs.count else {
            exit(0)
        }
        let job = jobs[index]
        let hosting = NSHostingController(rootView: job.view)
        if job.height == nil {
            hosting.sizingOptions = .preferredContentSize
        }
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.setContentSize(NSSize(width: job.width, height: job.height ?? 560))
        window.center()
        window.makeKeyAndOrderFront(nil)

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            await capture(window, to: outputDir.appendingPathComponent("\(job.name).png"))
            DispatchQueue.main.async {
                window.orderOut(nil)
                run(jobs, index: index + 1)
            }
        }
    }

    private static func capture(_ window: NSWindow, to destination: URL) async {
        guard let image = await captureImage(for: window) else {
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            return
        }
        try? data.write(to: destination)
    }

    private static func captureImage(for window: NSWindow) async -> CGImage? {
        let content: SCShareableContent
        do {
            if #available(macOS 14.4, *) {
                content = try await SCShareableContent.currentProcess
            } else {
                content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
            }
        } catch {
            return nil
        }

        guard let captureWindow = content.windows.first(where: {
            $0.windowID == CGWindowID(window.windowNumber)
        }) else {
            return nil
        }

        let filter = SCContentFilter(desktopIndependentWindow: captureWindow)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        configuration.ignoreShadowsSingleWindow = true
        configuration.showsCursor = false
        return try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
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
