import Foundation

public final class SyncEngine {
    private let configuration: AgentSyncConfiguration
    private let stateStore: BridgeStateStore
    private let claude: ClaudeAdapter
    private let codex: CodexAdapter
    private let opencode: OpenCodeAdapter

    /// Optional on-device summarizer for handoff briefs (e.g. Apple
    /// Intelligence). Returning nil falls back to the template digest.
    public var handoffSummarizer: (@Sendable (CanonicalSession) -> String?)?

    public init(
        configuration: AgentSyncConfiguration,
        stateStore: BridgeStateStore? = nil,
        claude: ClaudeAdapter = ClaudeAdapter(),
        codex: CodexAdapter = CodexAdapter(),
        opencode: OpenCodeAdapter = OpenCodeAdapter()
    ) {
        self.configuration = configuration
        self.stateStore = stateStore ?? BridgeStateStore(stateDirectory: configuration.stateDirectory)
        self.claude = claude
        self.codex = codex
        self.opencode = opencode
    }

    public func syncOnce() throws -> SyncReport {
        let importedClaude = try claude.importSessions(
            from: configuration.claudeHome,
            lookbackDays: configuration.sessionLookbackDays,
            maximumSessions: configuration.maximumImportedSessions
        )
        let importedCodex = try codex.importSessions(
            from: configuration.codexHome,
            lookbackDays: configuration.sessionLookbackDays,
            maximumSessions: configuration.maximumImportedSessions
        )

        return try sync(importedSessions: importedClaude + importedCodex)
    }

    public func syncSession(provider: AgentKind, sourcePath: String) throws -> SyncReport {
        guard let imported = try importSession(provider: provider, sourcePath: sourcePath) else {
            return .empty
        }
        return try sync(importedSessions: [imported])
    }

    public func currentState() throws -> BridgeState {
        try stateStore.load()
    }

    /// Converts one native session for the opposite provider and returns what
    /// to launch. This is the app's primary operation.
    ///
    /// `.auto` resolves to a handoff brief exactly when a full render would
    /// have to truncate the transcript to fit the context budget.
    public func prepareResume(
        provider: AgentKind,
        sourcePath: String,
        target explicitTarget: AgentKind? = nil,
        mode: ResumeMode = .auto
    ) throws -> ResumeTicket {
        let target = explicitTarget ?? provider.resumeTargets[0]
        guard target != provider else {
            throw AgentSyncError.invalidArguments("Resume target must differ from the source agent.")
        }
        guard let imported = try importSession(provider: provider, sourcePath: sourcePath) else {
            throw AgentSyncError.invalidArguments("No conversation content found in \(sourcePath).")
        }
        // Settle the canonical record first without rendering, so the mode
        // decision sees the merged transcript.
        _ = try sync(importedSessions: [imported], renderMirrors: false)

        var state = try stateStore.load()
        let nativeKey = BridgeState.nativeKey(provider: provider, sessionID: imported.sourceSessionID)
        guard let canonicalID = state.mirrorsByNativeSession[nativeKey]?.canonicalSessionID
            ?? state.canonicalByNativeSession[nativeKey] else {
            throw AgentSyncError.commandFailed("The session was imported but left no canonical record.")
        }
        guard let summary = state.canonicalSessions[canonicalID] else {
            throw AgentSyncError.commandFailed("No canonical record found for this conversation.")
        }
        // Mirrors are stored under their cwd's project (Claude resolves
        // --resume per project dir). If the original directory is gone —
        // deleted worktrees — render and launch must agree on the fallback,
        // or the launched CLI can't find the session we just wrote.
        var isDirectory: ObjCBool = false
        let cwdExists = FileManager.default.fileExists(atPath: summary.cwd, isDirectory: &isDirectory) && isDirectory.boolValue
        let cwd = cwdExists ? summary.cwd : FileManager.default.homeDirectoryForCurrentUser.path
        let events = try stateStore.loadEvents(canonicalSessionID: canonicalID)
        var session = CanonicalSession(summary: summary, events: events)
        session.cwd = cwd

        let effectiveMode: ResumeMode
        switch mode {
        case .auto:
            // Handoff exactly when a full render for THIS target's model would
            // have to truncate. OpenCode runs resumed sessions with the user's
            // own model regardless of what we stamp, so budget against that.
            let targetModel: String
            if target == .opencode {
                targetModel = configuration.opencodeResumeModel
                    ?? opencode.mostRecentModel(opencodeHome: configuration.opencodeHome)
                    ?? configuration.modelMappings.targetModel(for: session, targetProvider: target)
            } else {
                targetModel = configuration.modelMappings.targetModel(for: session, targetProvider: target)
            }
            let budget = transcriptByteBudget(forTargetModel: targetModel)
            effectiveMode = transcriptWindow(events, byteBudget: budget).omitted > 0 ? .handoff : .full
        default:
            effectiveMode = mode
        }

        if effectiveMode == .handoff {
            let mirror = try renderMirror(
                session: handoffSession(from: session, aiSummary: handoffSummarizer?(session)),
                target: target,
                state: &state,
                reuseExisting: false,
                kind: .handoff
            )
            try stateStore.save(state)
            return ResumeTicket(
                targetProvider: target,
                targetSessionID: mirror.targetSessionID,
                workingDirectory: cwd,
                usedHandoff: true
            )
        }

        // Full mode: the clicked session may itself be a mirror whose newest
        // events came from the target side — then the freshest full session on
        // the target is the origin/mirror we already have, not a re-render.
        if latestProvider(for: session) == target || session.events.isEmpty {
            if let mirror = state.latestMirror(canonicalSessionID: canonicalID, targetProvider: target) {
                return ResumeTicket(targetProvider: target, targetSessionID: mirror.targetSessionID, workingDirectory: cwd)
            }
            if summary.sourceProvider == target {
                return ResumeTicket(targetProvider: target, targetSessionID: summary.sourceSessionID, workingDirectory: cwd)
            }
        }

        let mirror = try renderMirror(session: session, target: target, state: &state, reuseExisting: true)
        try stateStore.save(state)
        return ResumeTicket(targetProvider: target, targetSessionID: mirror.targetSessionID, workingDirectory: cwd)
    }

    private func importSession(provider: AgentKind, sourcePath: String) throws -> CanonicalSession? {
        switch provider {
        case .claude:
            return try claude.importSession(from: URL(fileURLWithPath: sourcePath))
        case .codex:
            return try codex.importSession(from: URL(fileURLWithPath: sourcePath))
        case .opencode:
            // OpenCode sessions live in a database; the "path" is the ses_ id.
            return try opencode.importSession(sessionID: sourcePath, opencodeHome: configuration.opencodeHome)
        }
    }

    /// Renders one mirror of `session` for `target` and records it in state.
    /// With `reuseExisting`, the latest uncontinued mirror is rewritten in
    /// place; a continued (frozen) mirror is never reused — a fresh mirror is
    /// minted so the user's native turns survive.
    private func renderMirror(
        session: CanonicalSession,
        target: AgentKind,
        state: inout BridgeState,
        reuseExisting: Bool,
        kind: MirrorKind = .full
    ) throws -> MirrorRecord {
        let latest = reuseExisting
            ? state.mirrorsByNativeSession.values
                .filter { $0.canonicalSessionID == session.id && $0.targetProvider == target && $0.kind == kind }
                .max { $0.updatedAt < $1.updatedAt }
            : nil
        let existing = latest.flatMap { $0.importedNativeEventIDs.isEmpty ? $0 : nil }
        let targetSessionID = existing?.targetSessionID ?? Self.newTargetSessionID(for: target)
        var mirror: MirrorRecord
        switch target {
        case .claude:
            mirror = try claude.render(
                session: session,
                targetSessionID: targetSessionID,
                claudeHome: configuration.claudeHome,
                existingMirror: existing,
                defaultModel: configuration.modelMappings.targetModel(for: session, targetProvider: .claude),
                modelMappings: configuration.modelMappings
            )
        case .codex:
            mirror = try codex.render(
                session: session,
                targetSessionID: targetSessionID,
                codexHome: configuration.codexHome,
                existingMirror: existing,
                defaultModel: configuration.modelMappings.targetModel(for: session, targetProvider: .codex),
                modelMappings: configuration.modelMappings
            )
        case .opencode:
            // A configured resume model overrides both stamping and budgeting;
            // per-event mapping is skipped since one model was chosen.
            let configured = configuration.opencodeResumeModel
            mirror = try opencode.render(
                session: session,
                targetSessionID: targetSessionID,
                opencodeHome: configuration.opencodeHome,
                existingMirror: existing,
                defaultModel: configured ?? configuration.modelMappings.targetModel(for: session, targetProvider: .opencode),
                modelMappings: configured == nil ? configuration.modelMappings : nil,
                budgetModel: configured
            )
        }
        mirror.kind = kind
        let mirrorKey = BridgeState.nativeKey(provider: mirror.targetProvider, sessionID: mirror.targetSessionID)
        state.mirrorsByNativeSession[mirrorKey] = mirror
        return mirror
    }

    /// Session ids follow each provider's native shape so their own tooling
    /// (resume pickers, `--session` flags) accepts them.
    private static func newTargetSessionID(for target: AgentKind) -> String {
        switch target {
        case .claude, .codex:
            return UUID().uuidString.lowercased()
        case .opencode:
            let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24)
            return "ses_agsync\(hex)"
        }
    }

    private func sync(importedSessions: [CanonicalSession], renderMirrors: Bool = true) throws -> SyncReport {
        var state = try stateStore.load()
        var report = SyncReport.empty
        var touchedCanonicalIDs = Set<String>()

        // Events are loaded per canonical session on first use and written back
        // only when changed — the state file itself carries no transcripts.
        var eventsCache: [String: [CanonicalEvent]] = [:]
        var dirtyEventIDs = Set<String>()
        func events(for canonicalID: String) throws -> [CanonicalEvent] {
            if let cached = eventsCache[canonicalID] {
                return cached
            }
            let loaded = try stateStore.loadEvents(canonicalSessionID: canonicalID)
            eventsCache[canonicalID] = loaded
            return loaded
        }

        for imported in importedSessions {
            let nativeKey = BridgeState.nativeKey(provider: imported.sourceProvider, sessionID: imported.sourceSessionID)

            if let mirror = state.mirrorsByNativeSession[nativeKey] {
                let continuationCount = try importContinuation(
                    from: imported,
                    mirror: mirror,
                    state: &state,
                    eventsCache: &eventsCache,
                    dirtyEventIDs: &dirtyEventIDs
                )
                if continuationCount > 0 {
                    report.importedContinuations += continuationCount
                    touchedCanonicalIDs.insert(mirror.canonicalSessionID)
                } else {
                    report.skippedBridgeOwnedSources += 1
                }
                continue
            }

            let canonicalID = state.canonicalByNativeSession[nativeKey] ?? imported.id
            var summary: CanonicalSessionSummary
            var merged: [CanonicalEvent]
            if let existing = state.canonicalSessions[canonicalID] {
                summary = merge(existing: existing, imported: imported)
                merged = try events(for: canonicalID)
            } else {
                var session = imported
                session.id = canonicalID
                summary = CanonicalSessionSummary(session: session)
                merged = []
            }
            append(events: imported.events, to: &merged)
            eventsCache[canonicalID] = merged
            dirtyEventIDs.insert(canonicalID)

            state.canonicalByNativeSession[nativeKey] = canonicalID
            state.canonicalSessions[canonicalID] = summary
            touchedCanonicalIDs.insert(canonicalID)
            report.importedSessions += 1
        }

        if renderMirrors {
            for summary in state.canonicalSessions.values
                .filter({ touchedCanonicalIDs.contains($0.id) })
                .sorted(by: { $0.createdAt < $1.createdAt }) {
                let session = CanonicalSession(summary: summary, events: try events(for: summary.id))
                let latestProvider = latestProvider(for: session)
                // Ambient CLI sync mirrors only between claude and codex;
                // OpenCode mirrors are created solely on explicit resume.
                for target in [AgentKind.claude, .codex] where shouldRender(session: session, to: target, latestProvider: latestProvider) {
                    _ = try renderMirror(session: session, target: target, state: &state, reuseExisting: true)
                    report.renderedMirrors += 1
                }
            }
        }

        for canonicalID in dirtyEventIDs {
            try stateStore.saveEvents(eventsCache[canonicalID] ?? [], canonicalSessionID: canonicalID)
        }
        try stateStore.save(state)
        return report
    }

    private func shouldRender(session: CanonicalSession, to target: AgentKind, latestProvider: AgentKind?) -> Bool {
        target != (latestProvider ?? session.sourceProvider)
    }

    private func latestProvider(for session: CanonicalSession) -> AgentKind? {
        session.events.max { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.id < rhs.id
            }
            return lhs.timestamp < rhs.timestamp
        }?.sourceProvider
    }

    private func importContinuation(
        from imported: CanonicalSession,
        mirror: MirrorRecord,
        state: inout BridgeState,
        eventsCache: inout [String: [CanonicalEvent]],
        dirtyEventIDs: inout Set<String>
    ) throws -> Int {
        guard var summary = state.canonicalSessions[mirror.canonicalSessionID] else {
            return 0
        }

        var mirror = mirror
        var events = try eventsCache[summary.id] ?? stateStore.loadEvents(canonicalSessionID: summary.id)

        // Two guards against re-importing our own render: the recorded IDs, and
        // content identity with events the canonical already has. The second
        // catches any import/render asymmetry the ID lists would miss, so an
        // echo can never accumulate.
        let ignored = Set(mirror.renderedNativeEventIDs + mirror.importedNativeEventIDs)
        let knownContent = Set(events.map(eventContentKey))
        let continuationEvents = imported.events.filter {
            !ignored.contains($0.id)
                && !knownContent.contains(eventContentKey($0))
                && !isLegacyBridgeContextText($0.text)
        }
        guard !continuationEvents.isEmpty else {
            return 0
        }

        append(events: continuationEvents, to: &events)
        eventsCache[summary.id] = events
        dirtyEventIDs.insert(summary.id)

        summary.updatedAt = max(summary.updatedAt, imported.updatedAt)
        summary.model = imported.model ?? summary.model
        var providers = Set(summary.contributingProviders)
        providers.formUnion(continuationEvents.map(\.sourceProvider))
        summary.contributingProviders = AgentKind.allCases.filter { providers.contains($0) }
        state.canonicalSessions[summary.id] = summary

        var importedIDs = Set(mirror.importedNativeEventIDs)
        for event in continuationEvents {
            importedIDs.insert(event.id)
        }
        mirror.importedNativeEventIDs = importedIDs.sorted()
        mirror.updatedAt = Date()
        let mirrorKey = BridgeState.nativeKey(provider: mirror.targetProvider, sessionID: mirror.targetSessionID)
        state.mirrorsByNativeSession[mirrorKey] = mirror

        return continuationEvents.count
    }

    private func merge(existing: CanonicalSessionSummary, imported: CanonicalSession) -> CanonicalSessionSummary {
        var result = existing
        result.title = imported.title
        result.cwd = imported.cwd
        result.updatedAt = max(existing.updatedAt, imported.updatedAt)
        result.model = imported.model ?? existing.model
        result.sourcePath = imported.sourcePath

        var providers = Set(result.contributingProviders)
        providers.formUnion(imported.contributingProviders)
        result.contributingProviders = AgentKind.allCases.filter { providers.contains($0) }
        return result
    }

    private func append(events newEvents: [CanonicalEvent], to events: inout [CanonicalEvent]) {
        // Same-id events are replaced rather than skipped so a fresh import can
        // backfill fields older imports didn't capture (e.g. tool pairing ids).
        var indexByID = Dictionary(
            events.enumerated().map { ($1.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for event in newEvents {
            if let index = indexByID[event.id] {
                events[index] = event
            } else {
                indexByID[event.id] = events.count
                events.append(event)
            }
        }
        events.sort { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
    }
}
