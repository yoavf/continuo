import AgentSyncCore
import AppKit
import SwiftUI

/// Preferences are plain UserDefaults values; views bind to them with
/// @AppStorage using the same keys, and the model reads them when it builds a
/// configuration.
enum Prefs {
    static let claudeHomeKey = "claudeHomePath"
    static let codexHomeKey = "codexHomePath"
    static let opencodeHomeKey = "opencodeHomePath"
    static let stateDirectoryKey = "stateDirectoryPath"
    static let codexTargetModelKey = "codexTargetModel"
    static let claudeTargetModelKey = "claudeTargetModel"
    static let preferredTerminalKey = "preferredTerminal"

    static var production: AgentSyncConfiguration {
        AgentSyncConfiguration.productionDefault()
    }

    static var claudeHomePath: String {
        UserDefaults.standard.string(forKey: claudeHomeKey) ?? production.claudeHome.path
    }

    static var codexHomePath: String {
        UserDefaults.standard.string(forKey: codexHomeKey) ?? production.codexHome.path
    }

    static var opencodeHomePath: String {
        UserDefaults.standard.string(forKey: opencodeHomeKey) ?? production.opencodeHome.path
    }

    static var stateDirectoryPath: String {
        UserDefaults.standard.string(forKey: stateDirectoryKey) ?? production.stateDirectory.path
    }

    static var codexTargetModel: String {
        UserDefaults.standard.string(forKey: codexTargetModelKey) ?? production.defaultCodexModel
    }

    static var claudeTargetModel: String {
        UserDefaults.standard.string(forKey: claudeTargetModelKey) ?? production.defaultClaudeModel
    }

    static var preferredTerminal: TerminalApp {
        UserDefaults.standard.string(forKey: preferredTerminalKey)
            .flatMap(TerminalApp.init(rawValue:)) ?? .terminal
    }

    /// The split button's primary action: the target last used for sessions of
    /// this provider.
    static func primaryTarget(for provider: AgentKind) -> AgentKind {
        let stored = UserDefaults.standard.string(forKey: "lastTarget.\(provider.rawValue)")
            .flatMap(AgentKind.init(rawValue:))
        if let stored, stored != provider {
            return stored
        }
        return provider == .claude ? .codex : .claude
    }

    static func setPrimaryTarget(_ target: AgentKind, for provider: AgentKind) {
        UserDefaults.standard.set(target.rawValue, forKey: "lastTarget.\(provider.rawValue)")
    }

    static let modelPairsKey = "modelPairs"
    static let opencodeResumeModelKey = "opencodeResumeModel"
    static let transferModeKey = "transferMode"
    static let hotkeyEnabledKey = "hotkeyEnabled"

    static var hotkeyEnabled: Bool {
        UserDefaults.standard.object(forKey: hotkeyEnabledKey) as? Bool ?? true
    }

    static var transferMode: ResumeMode {
        UserDefaults.standard.string(forKey: transferModeKey)
            .flatMap(ResumeMode.init(rawValue:)) ?? .auto
    }

    /// Empty string means "OpenCode's own choice".
    static var opencodeResumeModel: String {
        UserDefaults.standard.string(forKey: opencodeResumeModelKey) ?? ""
    }

    /// Claude model → Codex model pairs; each pair applies in both directions.
    static func modelPairs() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: modelPairsKey) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    static func setModelPairs(_ pairs: [String: String]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(pairs), forKey: modelPairsKey)
    }

    /// Pair rules first (both directions; on a reverse conflict the
    /// alphabetically first Claude model wins), then the built-in family
    /// rules, then the direction defaults.
    static func modelMappings() -> ModelMappingSettings {
        var rules: [ModelMappingRule] = []
        for (claudeModel, codexModel) in modelPairs().sorted(by: { $0.key < $1.key }) where !codexModel.isEmpty {
            rules.append(ModelMappingRule(sourceProvider: .claude, targetProvider: .codex, sourcePattern: claudeModel, targetModel: codexModel))
            rules.append(ModelMappingRule(sourceProvider: .codex, targetProvider: .claude, sourcePattern: codexModel, targetModel: claudeModel))
        }
        rules.append(contentsOf: ModelMappingSettings.defaultRules(
            defaultCodexModel: codexTargetModel,
            defaultClaudeModel: claudeTargetModel
        ))
        return ModelMappingSettings(
            defaultCodexModel: codexTargetModel,
            defaultClaudeModel: claudeTargetModel,
            rules: rules
        )
    }

    /// Our mirrors leak target-provider model names into source transcripts;
    /// keep each side of the pair table to its own family.
    static func isClaudeFamilyModel(_ model: String) -> Bool {
        model.hasPrefix("claude")
    }

    static func configuration() -> AgentSyncConfiguration {
        AgentSyncConfiguration(
            claudeHome: expandedURL(claudeHomePath),
            codexHome: expandedURL(codexHomePath),
            opencodeHome: expandedURL(opencodeHomePath),
            stateDirectory: expandedURL(stateDirectoryPath),
            defaultCodexModel: codexTargetModel,
            defaultClaudeModel: claudeTargetModel,
            modelMappings: modelMappings(),
            opencodeResumeModel: opencodeResumeModel.isEmpty ? nil : opencodeResumeModel,
            sessionLookbackDays: 14,
            maximumImportedSessions: 10
        )
    }

    private static func expandedURL(_ path: String) -> URL {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true)
    }
}

enum AppStatus: Equatable {
    case idle
    case working(String)
    case notice(String)
    case error(String)
}

extension AgentKind {
    var displayName: String {
        switch self {
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        case .opencode:
            return "OpenCode"
        }
    }

    var symbolName: String {
        switch self {
        case .claude:
            return "asterisk"
        case .codex:
            return "chevron.left.forwardslash.chevron.right"
        case .opencode:
            return "circle.dotted.circle"
        }
    }

    var tint: Color {
        switch self {
        case .claude:
            return .orange
        case .codex:
            return .teal
        case .opencode:
            return .green
        }
    }

    var desktopBundleIdentifier: String {
        switch self {
        case .claude:
            return "com.anthropic.claudefordesktop"
        case .codex:
            return "com.openai.codex"
        case .opencode:
            return "ai.opencode.desktop"
        }
    }

    /// The agent's desktop app icon when installed, cached; nil falls back to
    /// the symbol badge.
    @MainActor var appIcon: NSImage? {
        AgentIconCache.icon(for: self)
    }

    /// A 16pt copy for menu items (menus ignore SwiftUI resizing on NSImage).
    @MainActor var menuIcon: NSImage? {
        guard let icon = appIcon else {
            return nil
        }
        let sized = icon.copy() as? NSImage
        sized?.size = NSSize(width: 16, height: 16)
        return sized
    }
}

@MainActor
private enum AgentIconCache {
    private static var cache: [AgentKind: NSImage?] = [:]

    static func icon(for agent: AgentKind) -> NSImage? {
        if let cached = cache[agent] {
            return cached
        }
        let icon: NSImage?
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: agent.desktopBundleIdentifier) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = nil
        }
        cache[agent] = icon
        return icon
    }
}

/// One row in the picker: a native session, possibly annotated as a bridge
/// mirror of a conversation that originated in the other tool.
struct SessionItem: Identifiable, Equatable, Sendable {
    var preview: SessionPreview
    var mirrorOrigin: AgentKind?
    /// On-device AI title, when the native one is just a raw prompt.
    var refinedTitle: String?

    var id: String { preview.id }
    var targets: [AgentKind] { preview.provider.resumeTargets }

    var primaryTarget: AgentKind {
        Prefs.primaryTarget(for: preview.provider)
    }

    var displayTitle: String {
        if let refinedTitle {
            return refinedTitle
        }
        let title = preview.title
        if title.hasPrefix("[Bridge] ") {
            return String(title.dropFirst("[Bridge] ".count))
        }
        return title
    }

    /// A "title" that is really an untrimmed prompt or injected context.
    var wantsRefinedTitle: Bool {
        guard refinedTitle == nil else {
            return false
        }
        let title = displayTitle
        return title.hasPrefix("#") || title.contains("<") || title.count >= 85
    }
}

@MainActor
final class AppModel: ObservableObject {
    /// One instance shared by the status-item popover, the Settings scene, and
    /// the global-hotkey panel.
    static let shared = AppModel()

    @Published var sessions: [SessionItem] = []
    @Published var observedModels: [AgentKind: [String]] = [:]
    @Published var status: AppStatus = .idle
    @Published var isRefreshing = false
    @Published var launchingID: String?
    @Published var isCMUXSetupAlertPresented = false

    private var refreshTimer: Timer?
    private var noticeResetTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var titleCache: [String: String] = [:]
    private var titleGenerationInFlight: Set<String> = []
    private let isDemo: Bool

    /// Demo instance for README screenshots: no scanning, timers, or hotkey, so
    /// injected `sessions` are never overwritten by a real session scan (which
    /// `SessionPickerView.onAppear` would otherwise trigger).
    init(demo: Bool) {
        isDemo = true
    }

    init() {
        isDemo = false
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        // Opening the status-item popover activates the app; refresh then so
        // the list is current even if the hosted view stays mounted between
        // openings.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        titleCache = Self.loadTitleCache()
        let stateDirectory = Prefs.configuration().stateDirectory
        // Load the cached/bundled catalog synchronously so budgets are exact
        // from the first scan; refresh from the network in the background.
        ModelCatalog.configure(stateDirectory: stateDirectory)
        Task.detached(priority: .utility) {
            ModelCatalog.refreshIfStale(stateDirectory: stateDirectory)
        }
        HotKeyCenter.shared.onHotKey = { [weak self] in
            guard let self else {
                return
            }
            QuickPicker.toggle(model: self)
        }
        applyHotkeySetting()
        refresh()
    }

    func applyHotkeySetting() {
        if Prefs.hotkeyEnabled {
            HotKeyCenter.shared.register()
        } else {
            HotKeyCenter.shared.unregister()
        }
    }

    var setupProblems: [String] {
        let fm = FileManager.default
        var problems: [String] = []
        if !fm.fileExists(atPath: NSString(string: Prefs.claudeHomePath).expandingTildeInPath) {
            problems.append("Claude Code home not found at \(Prefs.claudeHomePath)")
        }
        if !fm.fileExists(atPath: NSString(string: Prefs.codexHomePath).expandingTildeInPath) {
            problems.append("Codex home not found at \(Prefs.codexHomePath)")
        }
        return problems
    }

    func refresh() {
        guard !isDemo else {
            return
        }
        guard !isRefreshing, launchingID == nil else {
            return
        }
        isRefreshing = true
        let configuration = Prefs.configuration()

        Task.detached(priority: .utility) {
            let result = Result {
                try Self.loadSessions(configuration: configuration)
            }
            await MainActor.run {
                switch result {
                case .success(let (items, models)):
                    let decorated = items.map { item -> SessionItem in
                        var item = item
                        item.refinedTitle = self.titleCache[item.id]
                        return item
                    }
                    // Only notify SwiftUI when something actually changed —
                    // refresh fires on a 60s timer and on every popover open.
                    if decorated != self.sessions {
                        self.sessions = decorated
                    }
                    if models != self.observedModels {
                        self.observedModels = models
                    }
                    self.pruneTitleCache(keeping: decorated)
                    self.generateMissingTitles()
                case .failure(let error):
                    self.status = .error(String(describing: error))
                }
                self.isRefreshing = false
            }
        }
    }

    /// Fills in on-device AI titles for sessions whose native title is a raw
    /// prompt, a few per refresh, cached across launches.
    private func generateMissingTitles() {
        guard Intelligence.isAvailable else {
            return
        }
        let candidates = sessions
            .filter { $0.wantsRefinedTitle && !titleGenerationInFlight.contains($0.id) }
            .prefix(3)
        for item in candidates {
            titleGenerationInFlight.insert(item.id)
            let snippet = item.preview.snippet.isEmpty ? item.preview.title : item.preview.snippet
            Task.detached(priority: .utility) {
                let title = Intelligence.sessionTitle(from: snippet)
                await MainActor.run {
                    self.titleGenerationInFlight.remove(item.id)
                    guard let title else {
                        return
                    }
                    self.titleCache[item.id] = title
                    Self.saveTitleCache(self.titleCache)
                    if let index = self.sessions.firstIndex(where: { $0.id == item.id }) {
                        self.sessions[index].refinedTitle = title
                    }
                    self.generateMissingTitles()
                }
            }
        }
    }

    /// Drop cached AI titles for sessions that have aged out of the scan, so
    /// the cache doesn't grow without bound across launches.
    private func pruneTitleCache(keeping items: [SessionItem]) {
        let live = Set(items.map(\.id))
        let pruned = titleCache.filter { live.contains($0.key) }
        if pruned.count != titleCache.count {
            titleCache = pruned
            Self.saveTitleCache(pruned)
        }
    }

    nonisolated private static func titleCacheURL() -> URL {
        Prefs.configuration().stateDirectory.appendingPathComponent("title-cache.json")
    }

    nonisolated private static func loadTitleCache() -> [String: String] {
        guard let data = try? Data(contentsOf: titleCacheURL()) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private static func saveTitleCache(_ cache: [String: String]) {
        let url = titleCacheURL()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    func resume(_ item: SessionItem, target: AgentKind, mode explicitMode: ResumeMode? = nil) {
        let mode = explicitMode ?? Prefs.transferMode
        guard launchingID == nil, target != item.preview.provider else {
            return
        }
        let terminal = Prefs.preferredTerminal
        do {
            try TerminalLauncher.preflight(terminal)
        } catch {
            setStatus(.error(shortErrorText(error)))
            if case TerminalLaunchError.cmuxSetupRequired = error {
                isCMUXSetupAlertPresented = true
            }
            return
        }
        launchingID = item.id
        setStatus(.working("Preparing \(target.displayName) session…"))
        Prefs.setPrimaryTarget(target, for: item.preview.provider)
        let configuration = Prefs.configuration()

        Task.detached(priority: .userInitiated) {
            let result = Result {
                let engine = SyncEngine(configuration: configuration)
                engine.handoffSummarizer = Intelligence.handoffSummary
                let ticket = try engine.prepareResume(
                    provider: item.preview.provider,
                    sourcePath: item.preview.path,
                    target: target,
                    mode: mode
                )
                try TerminalLauncher.launch(ticket, using: terminal)
                return ticket
            }
            await MainActor.run {
                switch result {
                case .success(let ticket):
                    let text = ticket.usedHandoff
                        ? "Sent a handoff brief to \(ticket.targetProvider.displayName)"
                        : "Opened in \(ticket.targetProvider.displayName)"
                    self.setStatus(.notice(text), autoClear: true)
                case .failure(let error):
                    self.setStatus(.error(shortErrorText(error)))
                }
                self.launchingID = nil
                self.refresh()
            }
        }
    }

    func clearStatus() {
        setStatus(.idle)
    }

    private func setStatus(_ status: AppStatus, autoClear: Bool = false) {
        noticeResetTask?.cancel()
        self.status = status
        if autoClear {
            noticeResetTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else {
                    return
                }
                self?.status = .idle
            }
        }
    }

    nonisolated private static func loadSessions(
        configuration: AgentSyncConfiguration
    ) throws -> (items: [SessionItem], models: [AgentKind: [String]]) {
        let previews = try RecentSessionScanner.scan(
            claudeHome: configuration.claudeHome,
            codexHome: configuration.codexHome,
            opencodeHome: configuration.opencodeHome,
            lookbackDays: configuration.sessionLookbackDays,
            maximumPerProvider: 30
        )
        let state = (try? BridgeStateStore(stateDirectory: configuration.stateDirectory).load()) ?? .empty

        // One row per conversation. A mirror only outranks its origin when the
        // user actually continued it (its record has imported events) — a
        // mirror file's mtime moves on every render, which is not activity.
        var newestByCanonicalID: [String: (rank: Int, item: SessionItem)] = [:]
        var untracked: [SessionItem] = []

        for preview in previews {
            let mirror = state.mirrorsByNativeSession[preview.id]
            let canonicalID = mirror?.canonicalSessionID ?? state.canonicalByNativeSession[preview.id]
            let origin = mirror.flatMap { record in
                state.canonicalSessions[record.canonicalSessionID]?.sourceProvider ?? record.targetProvider.resumeTargets.first
            }
            let item = SessionItem(preview: preview, mirrorOrigin: origin)
            let isUntouchedMirror = mirror.map(\.importedNativeEventIDs.isEmpty) ?? false
            let rank = isUntouchedMirror ? 0 : 1

            guard let canonicalID else {
                untracked.append(item)
                continue
            }
            if let current = newestByCanonicalID[canonicalID],
               (current.rank, current.item.preview.updatedAt) >= (rank, preview.updatedAt) {
                continue
            }
            newestByCanonicalID[canonicalID] = (rank, item)
        }

        let items = (untracked + newestByCanonicalID.values.map(\.item)).sorted { lhs, rhs in
            if lhs.preview.updatedAt == rhs.preview.updatedAt {
                return lhs.id < rhs.id
            }
            return lhs.preview.updatedAt > rhs.preview.updatedAt
        }

        // Every model actually seen in transcripts, for the mapping table in
        // Settings. "agent-sync" and "<synthetic>" are placeholder values.
        var observed: [AgentKind: [String]] = [.claude: [], .codex: []]
        func note(_ model: String?, provider: AgentKind) {
            guard let model, !model.isEmpty, model != "agent-sync", !model.hasPrefix("<") else {
                return
            }
            if observed[provider]?.contains(model) != true {
                observed[provider, default: []].append(model)
            }
        }
        for preview in previews {
            for model in preview.models {
                note(model, provider: preview.provider)
            }
        }
        for summary in state.canonicalSessions.values {
            note(summary.model, provider: summary.sourceProvider)
        }
        observed[.claude]?.sort()
        observed[.codex]?.sort()

        return (items, observed)
    }
}

private func shortErrorText(_ error: Error) -> String {
    if let error = error as? AgentSyncError {
        return error.description
    }
    return error.localizedDescription
}
