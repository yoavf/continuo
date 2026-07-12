import Foundation
import Testing
@testable import AgentSyncCore

@Test func bidirectionalSyncCreatesNativeMirrorsWithoutTouchingSources() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("agent-sync-test-\(UUID().uuidString.lowercased())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let fixture = AgentSyncFixtureBuilder(root: root)
    try fixture.create()

    let claudeSource = fixture.claudeHome
        .appendingPathComponent("projects", isDirectory: true)
        .appendingPathComponent(PathEncoding.claudeProjectName(for: fixture.workspace.path), isDirectory: true)
        .appendingPathComponent("11111111-1111-4111-8111-111111111111.jsonl")
    let codexSource = findOnlyCodexSource(in: fixture.codexHome)
    let claudeBefore = try String(contentsOf: claudeSource, encoding: .utf8)
    let codexBefore = try String(contentsOf: codexSource, encoding: .utf8)

    let engine = SyncEngine(configuration: fixture.configuration())
    let first = try engine.syncOnce()
    let state = try engine.currentState()

    #expect(first.importedSessions == 2)
    #expect(first.renderedMirrors == 2)
    #expect(first.skippedBridgeOwnedSources == 0)
    #expect(state.canonicalSessions.count == 2)
    #expect(state.mirrorsByNativeSession.count == 2)

    let codexMirror = try #require(state.mirrorsByNativeSession.values.first { $0.targetProvider == .codex })
    let claudeMirror = try #require(state.mirrorsByNativeSession.values.first { $0.targetProvider == .claude })
    #expect(FileManager.default.fileExists(atPath: codexMirror.targetPath))
    #expect(FileManager.default.fileExists(atPath: claudeMirror.targetPath))
    #expect(claudeMirror.targetIndexPath == nil)
    #expect(!FileManager.default.fileExists(atPath: fixture.claudeHome.appendingPathComponent("sessions").path))
    #expect(!codexMirror.renderedNativeEventIDs.isEmpty)
    #expect(!claudeMirror.renderedNativeEventIDs.isEmpty)

    let codexMirrorText = try String(contentsOfFile: codexMirror.targetPath, encoding: .utf8)
    let claudeMirrorText = try String(contentsOfFile: claudeMirror.targetPath, encoding: .utf8)
    #expect(codexMirrorText.contains("Build a tiny parser in Swift."))
    #expect(claudeMirrorText.contains("Port this shell script to Swift."))

    // The codex mirror must deserialize as a Codex rollout: no base_instructions
    // stub, thread_source present, and tool calls paired with their outputs via
    // the original tool id (orphaned outputs are dropped on resume).
    #expect(!codexMirrorText.contains("base_instructions"))
    #expect(codexMirrorText.contains("\"thread_source\":\"user\""))
    #expect(codexMirrorText.contains("\"summary\":\"auto\""))
    let pairedCallIDs = codexMirrorText.components(separatedBy: "\"call_id\":\"toolu_fixture_1\"").count - 1
    #expect(pairedCallIDs == 2)
    let importedCodexMaybe = try CodexAdapter().importSession(from: codexSource)
    let importedCodexSource = try #require(importedCodexMaybe)
    #expect(importedCodexSource.events.filter { $0.text == "Port this shell script to Swift." }.count == 1)
    #expect(!FileManager.default.fileExists(atPath: fixture.codexHome.appendingPathComponent("state_5.sqlite").path))

    #expect(try String(contentsOf: claudeSource, encoding: .utf8) == claudeBefore)
    #expect(try String(contentsOf: codexSource, encoding: .utf8) == codexBefore)

    let second = try engine.syncOnce()
    let stateAfterSecond = try engine.currentState()
    #expect(second.skippedBridgeOwnedSources == 2)
    #expect(stateAfterSecond.canonicalSessions.count == 2)
    #expect(stateAfterSecond.mirrorsByNativeSession.count == 2)
}

@Test func continuationInBridgeOwnedMirrorsRoundTripsWithoutRewritingLatestProvider() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("agent-sync-continuation-\(UUID().uuidString.lowercased())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let fixture = AgentSyncFixtureBuilder(root: root)
    try fixture.create()
    let claudeSource = fixture.claudeHome
        .appendingPathComponent("projects", isDirectory: true)
        .appendingPathComponent(PathEncoding.claudeProjectName(for: fixture.workspace.path), isDirectory: true)
        .appendingPathComponent("11111111-1111-4111-8111-111111111111.jsonl")
    let claudeSourceBefore = try String(contentsOf: claudeSource, encoding: .utf8)

    let engine = SyncEngine(configuration: fixture.configuration())
    _ = try engine.syncOnce()
    let initialState = try engine.currentState()
    let claudeCanonical = try #require(initialState.canonicalSessions.values.first {
        $0.sourceProvider == .claude && $0.sourceSessionID == "11111111-1111-4111-8111-111111111111"
    })
    let codexMirror = try #require(initialState.mirrorsByNativeSession.values.first {
        $0.canonicalSessionID == claudeCanonical.id && $0.targetProvider == .codex
    })

    try appendCodexContinuation(
        to: URL(fileURLWithPath: codexMirror.targetPath),
        sessionID: codexMirror.targetSessionID,
        userText: "Continue this from the Codex mirror.",
        assistantText: "Codex mirror continuation captured.",
        timestamp: Date(timeIntervalSince1970: 1_783_000_301)
    )
    let codexMirrorAfterNativeContinuation = try String(contentsOfFile: codexMirror.targetPath, encoding: .utf8)

    let codexContinuationReport = try engine.syncOnce()
    let afterCodexContinuation = try engine.currentState()
    #expect(codexContinuationReport.importedContinuations == 2)

    let store = BridgeStateStore(stateDirectory: fixture.stateDirectory)
    let updatedCanonical = try #require(afterCodexContinuation.canonicalSessions[claudeCanonical.id])
    #expect(updatedCanonical.contributingProviders.contains(.codex))
    #expect(try store.loadEvents(canonicalSessionID: claudeCanonical.id)
        .contains { $0.text == "Continue this from the Codex mirror." })

    let sourceSideClaudeMirror = try #require(afterCodexContinuation.mirrorsByNativeSession.values.first {
        $0.canonicalSessionID == claudeCanonical.id && $0.targetProvider == .claude
    })
    let sourceSideClaudeMirrorText = try String(contentsOfFile: sourceSideClaudeMirror.targetPath, encoding: .utf8)
    #expect(sourceSideClaudeMirrorText.contains("Continue this from the Codex mirror."))
    #expect(try String(contentsOfFile: codexMirror.targetPath, encoding: .utf8) == codexMirrorAfterNativeContinuation)
    #expect(try String(contentsOf: claudeSource, encoding: .utf8) == claudeSourceBefore)

    try appendClaudeContinuation(
        to: URL(fileURLWithPath: sourceSideClaudeMirror.targetPath),
        sessionID: sourceSideClaudeMirror.targetSessionID,
        cwd: fixture.workspace.path,
        userText: "Back from the Claude mirror.",
        assistantText: "Claude-side continuation captured.",
        timestamp: Date(timeIntervalSince1970: 1_783_000_401)
    )

    let claudeContinuationReport = try engine.syncOnce()
    let afterClaudeContinuation = try engine.currentState()
    #expect(claudeContinuationReport.importedContinuations == 2)
    #expect(afterClaudeContinuation.canonicalSessions[claudeCanonical.id] != nil)
    #expect(try store.loadEvents(canonicalSessionID: claudeCanonical.id)
        .contains { $0.text == "Back from the Claude mirror." })

    // The continued codex mirror is frozen: rendering back to codex must mint a
    // fresh mirror and leave the continued file byte-identical.
    let codexMirrors = afterClaudeContinuation.mirrorsByNativeSession.values.filter {
        $0.canonicalSessionID == claudeCanonical.id && $0.targetProvider == .codex
    }
    #expect(codexMirrors.count == 2)
    let refreshedCodexMirror = try #require(
        afterClaudeContinuation.latestMirror(canonicalSessionID: claudeCanonical.id, targetProvider: .codex)
    )
    #expect(refreshedCodexMirror.targetSessionID != codexMirror.targetSessionID)
    let refreshedCodexMirrorText = try String(contentsOfFile: refreshedCodexMirror.targetPath, encoding: .utf8)
    #expect(refreshedCodexMirrorText.contains("Back from the Claude mirror."))
    #expect(try String(contentsOfFile: codexMirror.targetPath, encoding: .utf8) == codexMirrorAfterNativeContinuation)
    #expect(try String(contentsOf: claudeSource, encoding: .utf8) == claudeSourceBefore)
}

@Test func codexRendererIndexesExistingThreadDatabase() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("agent-sync-index-\(UUID().uuidString.lowercased())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
    try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
    try createMinimalThreadsTable(codexHome.appendingPathComponent("state_5.sqlite"))

    let now = Date(timeIntervalSince1970: 1_783_000_201)
    let session = CanonicalSession(
        id: "canonical-index-test",
        sourceProvider: .claude,
        sourceSessionID: "source-1",
        sourcePath: root.appendingPathComponent("source.jsonl").path,
        title: "Index me",
        cwd: root.path,
        createdAt: now,
        updatedAt: now,
        model: "claude-fixture",
        contributingProviders: [.claude],
        events: [
            CanonicalEvent(
                id: "event-1",
                sourceProvider: .claude,
                sourceEventID: "event-1",
                timestamp: now,
                role: .user,
                kind: "message",
                text: "Please index this mirror."
            )
        ]
    )

    let mirror = try CodexAdapter().render(
        session: session,
        targetSessionID: "33333333-3333-4333-8333-333333333333",
        codexHome: codexHome,
        existingMirror: nil,
        defaultModel: "gpt-5.5"
    )

    #expect(mirror.targetIndexPath == codexHome.appendingPathComponent("state_5.sqlite").path)
    #expect(try sqliteThreadCount(codexHome.appendingPathComponent("state_5.sqlite")) == 1)
    #expect(try sqliteScalar(codexHome.appendingPathComponent("state_5.sqlite"), "select thread_source from threads limit 1;") == "user")
}

@Test func prepareResumeConvertsOneSessionAndResolvesTheOppositeProvider() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("agent-sync-resume-\(UUID().uuidString.lowercased())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let fixture = AgentSyncFixtureBuilder(root: root)
    try fixture.create()
    let claudeSource = fixture.claudeHome
        .appendingPathComponent("projects", isDirectory: true)
        .appendingPathComponent(PathEncoding.claudeProjectName(for: fixture.workspace.path), isDirectory: true)
        .appendingPathComponent("11111111-1111-4111-8111-111111111111.jsonl")

    let engine = SyncEngine(configuration: fixture.configuration())
    let ticket = try engine.prepareResume(provider: .claude, sourcePath: claudeSource.path)

    #expect(ticket.targetProvider == .codex)
    #expect(ticket.workingDirectory == fixture.workspace.path)
    let state = try engine.currentState()
    let mirror = try #require(state.mirrorsByNativeSession.values.first { $0.targetProvider == .codex })
    #expect(ticket.targetSessionID == mirror.targetSessionID)
    #expect(FileManager.default.fileExists(atPath: mirror.targetPath))
    // Only the requested session converts — the codex source stays untouched.
    #expect(state.canonicalSessions.count == 1)

    // Resuming the freshly created codex mirror back toward Claude resolves to
    // the original native Claude session instead of minting another mirror.
    let roundTrip = try engine.prepareResume(provider: .codex, sourcePath: mirror.targetPath)
    #expect(roundTrip.targetProvider == .claude)
    #expect(roundTrip.targetSessionID == "11111111-1111-4111-8111-111111111111")
}

@Test func failedNativeWriteKeepsOwnershipReservationForRetry() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("agent-sync-resume-recovery-\(UUID().uuidString.lowercased())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let fixture = AgentSyncFixtureBuilder(root: root)
    try fixture.create()
    let codexSource = findOnlyCodexSource(in: fixture.codexHome)
    let sourceBefore = try Data(contentsOf: codexSource)

    let blockedClaudeHome = root.appendingPathComponent("blocked-claude-home", isDirectory: true)
    try FileManager.default.createDirectory(at: blockedClaudeHome, withIntermediateDirectories: true)
    let projectsPath = blockedClaudeHome.appendingPathComponent("projects")
    try Data("not a directory".utf8).write(to: projectsPath)

    let configuration = AgentSyncConfiguration(
        claudeHome: blockedClaudeHome,
        codexHome: fixture.codexHome,
        stateDirectory: fixture.stateDirectory,
        defaultCodexModel: "gpt-5.5",
        defaultClaudeModel: "claude-sonnet-5"
    )
    let engine = SyncEngine(configuration: configuration)

    do {
        _ = try engine.prepareResume(
            provider: .codex,
            sourcePath: codexSource.path,
            target: .claude,
            mode: .handoff
        )
        Issue.record("Expected the blocked Claude home to reject the native write.")
    } catch {
        // The failed write is the interruption point under test.
    }

    let reservedState = try engine.currentState()
    let reservation = try #require(reservedState.mirrorsByNativeSession.values.first {
        $0.targetProvider == .claude
    })
    #expect(reservation.isPendingWrite)
    #expect(!reservation.renderedNativeEventIDs.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: reservation.targetPath))
    #expect(try Data(contentsOf: codexSource) == sourceBefore)

    try FileManager.default.removeItem(at: projectsPath)
    let ticket = try engine.prepareResume(
        provider: .codex,
        sourcePath: codexSource.path,
        target: .claude,
        mode: .handoff
    )
    let recoveredState = try engine.currentState()

    #expect(ticket.targetSessionID == reservation.targetSessionID)
    #expect(ticket.usedHandoff)
    #expect(recoveredState.mirrorsByNativeSession.values.filter { $0.targetProvider == .claude }.count == 1)
    #expect(recoveredState.mirrorsByNativeSession.values.allSatisfy { !$0.isPendingWrite })
    #expect(FileManager.default.fileExists(atPath: reservation.targetPath))
    #expect(try Data(contentsOf: codexSource) == sourceBefore)
}

@Test func missingStateAfterNativeCreationRecoversWithoutDuplicate() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("agent-sync-post-write-recovery-\(UUID().uuidString.lowercased())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let fixture = AgentSyncFixtureBuilder(root: root)
    try fixture.create()
    let codexSource = findOnlyCodexSource(in: fixture.codexHome)
    let sourceBefore = try Data(contentsOf: codexSource)
    let engine = SyncEngine(configuration: fixture.configuration())

    let first = try engine.prepareResume(
        provider: .codex,
        sourcePath: codexSource.path,
        target: .claude,
        mode: .handoff
    )
    let firstState = try engine.currentState()
    let firstMirror = try #require(firstState.mirrorsByNativeSession.values.first {
        $0.targetSessionID == first.targetSessionID
    })
    #expect(FileManager.default.fileExists(atPath: firstMirror.targetPath))

    // The backup captured the pending reservation immediately before the
    // native write. Losing the primary file models an interrupted legacy
    // delete-then-move finalization after that native session already exists.
    try FileManager.default.removeItem(at: fixture.stateDirectory.appendingPathComponent("bridge-state.json"))

    let recovered = try engine.prepareResume(
        provider: .codex,
        sourcePath: codexSource.path,
        target: .claude,
        mode: .handoff
    )
    let recoveredState = try engine.currentState()

    #expect(recovered.targetSessionID == first.targetSessionID)
    #expect(recoveredState.mirrorsByNativeSession.values.filter { $0.targetProvider == .claude }.count == 1)
    #expect(recoveredState.mirrorsByNativeSession.values.allSatisfy { !$0.isPendingWrite })
    #expect(FileManager.default.fileExists(atPath: firstMirror.targetPath))
    #expect(try Data(contentsOf: codexSource) == sourceBefore)
}

@Test func handoffModeRendersBriefPlusRecentTurnsAsAFreshMirror() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("agent-sync-handoff-\(UUID().uuidString.lowercased())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let fixture = AgentSyncFixtureBuilder(root: root)
    try fixture.create()
    let claudeSource = fixture.claudeHome
        .appendingPathComponent("projects", isDirectory: true)
        .appendingPathComponent(PathEncoding.claudeProjectName(for: fixture.workspace.path), isDirectory: true)
        .appendingPathComponent("11111111-1111-4111-8111-111111111111.jsonl")

    let engine = SyncEngine(configuration: fixture.configuration())
    let full = try engine.prepareResume(provider: .claude, sourcePath: claudeSource.path, mode: .full)
    let handoff = try engine.prepareResume(provider: .claude, sourcePath: claudeSource.path, mode: .handoff)

    #expect(!full.usedHandoff)
    #expect(handoff.usedHandoff)
    #expect(handoff.targetSessionID != full.targetSessionID)

    let state = try engine.currentState()
    let handoffMirror = try #require(state.mirrorsByNativeSession.values.first {
        $0.targetSessionID == handoff.targetSessionID
    })
    let text = try String(contentsOfFile: handoffMirror.targetPath, encoding: .utf8)
    #expect(text.contains("[Continuo handoff brief]"))
    #expect(text.contains("Build a tiny parser in Swift."))
    // Tool traffic is dropped in a handoff.
    #expect(!text.contains("function_call"))

    // A small session in auto mode stays full — no brief.
    let auto = try engine.prepareResume(provider: .claude, sourcePath: claudeSource.path, mode: .auto)
    #expect(!auto.usedHandoff)
    #expect(auto.targetSessionID == full.targetSessionID)
}

@Test func toolNamesRenderInTheTargetAgentsVocabulary() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("agent-sync-taxonomy-\(UUID().uuidString.lowercased())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let fixture = AgentSyncFixtureBuilder(root: root)
    try fixture.create()
    let codexSource = findOnlyCodexSource(in: fixture.codexHome)
    try appendCodexToolEvents(to: codexSource, timestamp: Date(timeIntervalSince1970: 1_783_000_111))

    let engine = SyncEngine(configuration: fixture.configuration())
    _ = try engine.syncOnce()
    let state = try engine.currentState()

    // Claude's Bash call shows up in Codex as exec_command…
    let claudeCanonical = try #require(state.canonicalSessions.values.first { $0.sourceProvider == .claude })
    let codexMirror = try #require(state.latestMirror(canonicalSessionID: claudeCanonical.id, targetProvider: .codex))
    let codexText = try String(contentsOfFile: codexMirror.targetPath, encoding: .utf8)
    #expect(codexText.contains("\"name\":\"exec_command\""))
    #expect(!codexText.contains("\"name\":\"Bash\""))

    // …and Codex's exec_command shows up in Claude as Bash.
    let codexCanonical = try #require(state.canonicalSessions.values.first { $0.sourceProvider == .codex })
    let claudeMirror = try #require(state.latestMirror(canonicalSessionID: codexCanonical.id, targetProvider: .claude))
    let claudeText = try String(contentsOfFile: claudeMirror.targetPath, encoding: .utf8)
    #expect(claudeText.contains("\"name\":\"Bash\""))
    #expect(!claudeText.contains("\"name\":\"exec_command\""))
}

@Test func providerLocalNoiseIsOmittedFromMirrors() throws {
    let base = Date(timeIntervalSince1970: 1_783_000_801)
    func event(
        _ index: Int,
        role: CanonicalRole = .user,
        text: String
    ) -> CanonicalEvent {
        CanonicalEvent(
            id: "noise-\(index)",
            sourceProvider: .claude,
            sourceEventID: "noise-\(index)",
            timestamp: base.addingTimeInterval(Double(index)),
            role: role,
            kind: "message",
            text: text
        )
    }
    let session = CanonicalSession(
        id: "canonical-noise",
        sourceProvider: .claude,
        sourceSessionID: "noise-1",
        sourcePath: "/tmp/noise.jsonl",
        title: "Noise test",
        cwd: NSTemporaryDirectory(),
        createdAt: base,
        updatedAt: base,
        model: "claude-fable-5",
        contributingProviders: [.claude],
        events: [
            event(0, text: "<command-name>/effort</command-name>\n<command-message>effort</command-message>"),
            event(1, text: "<local-command-stdout>Set effort level to high</local-command-stdout>"),
            event(2, text: """
            <task-notification>
            <task-id>task-1</task-id>
            <status>killed</status>
            <summary>Background command was stopped</summary>
            </task-notification>
            """),
            event(3, role: .assistant, text: "No response requested."),
            event(4, text: "Continue from where you left off."),
            event(5, text: "<bash-input>open docs/index.html</bash-input>"),
            event(6, text: "<bash-stdout>(Bash completed with no output)</bash-stdout>"),
            event(7, text: "Real question about the build system.")
        ]
    )

    // Classification-side: known provider control messages are all noise.
    #expect(isProviderLocalNoise(session.events[0].text))
    #expect(isProviderLocalNoise(session.events[1].text))
    #expect(isProviderLocalNoise(session.events[2].text))
    #expect(isProviderLocalNoise(session.events[3].text))
    #expect(isProviderLocalNoise(session.events[4].text))
    #expect(isProviderLocalNoise(session.events[5].text))
    #expect(isProviderLocalNoise(session.events[6].text))
    #expect(!isProviderLocalNoise(session.events[7].text))

    // Render-side: pre-existing noise in canonical data is skipped too.
    let built = OpenCodeAdapter().buildExport(
        session: session,
        targetSessionID: "ses_agsyncnoise01",
        database: nil,
        defaultModel: "anthropic/claude-fable-5",
        modelMappings: nil
    )
    let encoded = String(data: try JSONEncoder().encode(JSONValue.object(built.export)), encoding: .utf8) ?? ""
    #expect(!encoded.contains("command-name"))
    #expect(!encoded.contains("local-command-stdout"))
    #expect(!encoded.contains("task-notification"))
    #expect(!encoded.contains("No response requested."))
    #expect(!encoded.contains("Continue from where you left off."))
    #expect(!encoded.contains("bash-input"))
    #expect(!encoded.contains("bash-stdout"))
    #expect(encoded.contains("Real question about the build system."))
}

@Test func openCodeSessionReplacementCascadesToOldMessagesAndParts() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("agent-sync-opencode-cleanup-\(UUID().uuidString.lowercased())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let database = root.appendingPathComponent("opencode.db")

    try OpenCodeSQL.execute(database: database, sql: """
    CREATE TABLE session (id TEXT PRIMARY KEY);
    CREATE TABLE message (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE
    );
    CREATE TABLE part (
        id TEXT PRIMARY KEY,
        message_id TEXT NOT NULL REFERENCES message(id) ON DELETE CASCADE
    );
    INSERT INTO session VALUES ('session-1');
    INSERT INTO message VALUES ('message-1', 'session-1');
    INSERT INTO part VALUES ('part-1', 'message-1');
    """)

    try OpenCodeSQL.execute(
        database: database,
        sql: "DELETE FROM session WHERE id = 'session-1';"
    )

    #expect(try sqliteScalar(database, "SELECT count(*) FROM message;") == "0")
    #expect(try sqliteScalar(database, "SELECT count(*) FROM part;") == "0")
}

@Test func codexToolEventsRenderAsClaudeToolBlocksNotVisibleContextMessages() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("agent-sync-tool-fidelity-\(UUID().uuidString.lowercased())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let fixture = AgentSyncFixtureBuilder(root: root)
    try fixture.create()
    let codexSource = findOnlyCodexSource(in: fixture.codexHome)
    try appendCodexToolEvents(
        to: codexSource,
        timestamp: Date(timeIntervalSince1970: 1_783_000_111)
    )

    let engine = SyncEngine(configuration: fixture.configuration())
    _ = try engine.syncOnce()
    let state = try engine.currentState()
    let codexCanonical = try #require(state.canonicalSessions.values.first {
        $0.sourceProvider == .codex && $0.sourceSessionID == "22222222-2222-4222-8222-222222222222"
    })
    let claudeMirror = try #require(state.mirrorsByNativeSession.values.first {
        $0.canonicalSessionID == codexCanonical.id && $0.targetProvider == .claude
    })

    let text = try String(contentsOfFile: claudeMirror.targetPath, encoding: .utf8)
    #expect(!text.contains("[Tool context from codex]"))
    #expect(text.contains("\"type\":\"tool_use\""))
    #expect(text.contains("\"type\":\"tool_result\""))
    // The call and its result must share the source call id.
    #expect(text.components(separatedBy: "call_fixture_tool").count - 1 >= 2)

    // Re-scanning must not mistake our own rendered tool events for user
    // continuations — that asymmetry is how the old echo loop snowballed.
    let second = try engine.syncOnce()
    #expect(second.importedContinuations == 0)
}

@Test func legacyMonolithicStateMigratesToSummariesPlusEventFiles() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("agent-sync-migrate-\(UUID().uuidString.lowercased())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let legacyJSON = """
    {
      "schemaVersion" : 1,
      "canonicalByNativeSession" : { "claude:source-1" : "canonical-1" },
      "canonicalSessions" : {
        "canonical-1" : {
          "id" : "canonical-1",
          "sourceProvider" : "claude",
          "sourceSessionID" : "source-1",
          "sourcePath" : "/tmp/source.jsonl",
          "title" : "Legacy session",
          "cwd" : "/tmp",
          "createdAt" : "2026-07-01T10:00:00Z",
          "updatedAt" : "2026-07-01T10:05:00Z",
          "contributingProviders" : [ "claude" ],
          "events" : [ {
            "id" : "claude:source-1:event-1",
            "sourceProvider" : "claude",
            "sourceEventID" : "event-1",
            "timestamp" : "2026-07-01T10:00:00Z",
            "role" : "user",
            "kind" : "message",
            "text" : "Hello from the legacy blob.",
            "metadata" : { }
          } ]
        }
      },
      "mirrorsByNativeSession" : { }
    }
    """
    try legacyJSON.write(
        to: root.appendingPathComponent("bridge-state.json"),
        atomically: true,
        encoding: .utf8
    )
    try "old backup".write(
        to: root.appendingPathComponent("bridge-state.backup.json"),
        atomically: true,
        encoding: .utf8
    )

    let store = BridgeStateStore(stateDirectory: root)
    let state = try store.load()

    #expect(state.canonicalSessions["canonical-1"]?.title == "Legacy session")
    #expect(try store.loadEvents(canonicalSessionID: "canonical-1")
        .contains { $0.text == "Hello from the legacy blob." })

    // The state file is rewritten as v2 and the legacy full-size backup is gone.
    let rewritten = try String(
        contentsOf: root.appendingPathComponent("bridge-state.json"),
        encoding: .utf8
    )
    #expect(rewritten.contains("\"schemaVersion\" : 2"))
    #expect(!rewritten.contains("Hello from the legacy blob."))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("bridge-state.backup.json").path))

    // Loading again is a plain v2 read, and events survive.
    let reloaded = try store.load()
    #expect(reloaded.canonicalSessions.count == 1)
    #expect(try store.loadEvents(canonicalSessionID: "canonical-1").count == 1)
}

@Test func bridgeStateRecoversFromBackupWhenPrimaryIsMissing() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("agent-sync-state-recovery-\(UUID().uuidString.lowercased())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = BridgeStateStore(stateDirectory: root)
    var recoverable = BridgeState.empty
    recoverable.canonicalByNativeSession["codex:source"] = "canonical-source"
    try store.save(recoverable)

    var newer = recoverable
    newer.canonicalByNativeSession["claude:mirror"] = "canonical-source"
    try store.save(newer)

    try FileManager.default.removeItem(at: root.appendingPathComponent("bridge-state.json"))
    let recovered = try store.load()

    #expect(recovered == recoverable)
}

@Test func nativeFileWriterRefusesUnownedOverwrite() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("agent-sync-writer-\(UUID().uuidString.lowercased())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("native.jsonl")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "source\n".write(to: file, atomically: true, encoding: .utf8)

    do {
        try NativeFileWriter.writeAtomically(
            text: "replacement\n",
            to: file,
            replacingExistingBridgeFile: false,
            allowedRoot: root
        )
        Issue.record("Expected unowned overwrite to fail.")
    } catch AgentSyncError.unsafeWrite {
        #expect(try String(contentsOf: file, encoding: .utf8) == "source\n")
    }
}

@Test func overlappingBridgeMutationsRunOneAtATime() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("agent-sync-mutation-lock-\(UUID().uuidString.lowercased())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let firstEntered = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    let secondEntered = DispatchSemaphore(value: 0)
    let finished = DispatchGroup()

    finished.enter()
    DispatchQueue.global().async {
        defer { finished.leave() }
        let store = BridgeStateStore(stateDirectory: root)
        _ = try? store.withExclusiveMutation {
            firstEntered.signal()
            releaseFirst.wait()
        }
    }
    #expect(firstEntered.wait(timeout: .now() + 2) == .success)

    finished.enter()
    DispatchQueue.global().async {
        defer { finished.leave() }
        let store = BridgeStateStore(stateDirectory: root)
        _ = try? store.withExclusiveMutation {
            secondEntered.signal()
        }
    }

    #expect(secondEntered.wait(timeout: .now() + 0.15) == .timedOut)
    releaseFirst.signal()
    #expect(secondEntered.wait(timeout: .now() + 2) == .success)
    #expect(finished.wait(timeout: .now() + 2) == .success)
}

@Test func bridgeMutationLockSerializesAcrossProcesses() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("agent-sync-process-lock-\(UUID().uuidString.lowercased())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let script = """
    import fcntl, pathlib, sys, time
    root = pathlib.Path(sys.argv[1])
    lock = root / ".bridge-state.lock"
    counter = root / "counter"
    ready = root / "child-ready"
    with lock.open("a+") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        value = int(counter.read_text()) if counter.exists() else 0
        ready.write_text("ready")
        time.sleep(0.25)
        counter.write_text(str(value + 1))
    """
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    child.arguments = ["-c", script, root.path]
    child.standardOutput = Pipe()
    child.standardError = Pipe()
    try child.run()

    let readyURL = root.appendingPathComponent("child-ready")
    let readyDeadline = Date().addingTimeInterval(2)
    while !FileManager.default.fileExists(atPath: readyURL.path), Date() < readyDeadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    #expect(FileManager.default.fileExists(atPath: readyURL.path))

    let counterURL = root.appendingPathComponent("counter")
    let store = BridgeStateStore(stateDirectory: root)
    try store.withExclusiveMutation {
        let value = (try? String(contentsOf: counterURL, encoding: .utf8)).flatMap(Int.init) ?? 0
        try String(value + 1).write(to: counterURL, atomically: true, encoding: .utf8)
    }
    child.waitUntilExit()

    #expect(child.terminationStatus == 0)
    #expect(try String(contentsOf: counterURL, encoding: .utf8) == "2")
}

@Test func modelMappingUsesProviderRulesThenFallsBackToDefaults() throws {
    let now = Date(timeIntervalSince1970: 1_783_000_501)
    let claudeSession = CanonicalSession(
        id: "canonical-claude-model",
        sourceProvider: .claude,
        sourceSessionID: "claude-model",
        sourcePath: "/tmp/claude.jsonl",
        title: "Claude model",
        cwd: "/tmp",
        createdAt: now,
        updatedAt: now,
        model: "claude-sonnet-4-5-20260701",
        contributingProviders: [.claude],
        events: []
    )
    let codexSession = CanonicalSession(
        id: "canonical-codex-model",
        sourceProvider: .codex,
        sourceSessionID: "codex-model",
        sourcePath: "/tmp/codex.jsonl",
        title: "Codex model",
        cwd: "/tmp",
        createdAt: now,
        updatedAt: now,
        model: "gpt-5.5-codex",
        contributingProviders: [.codex],
        events: []
    )
    let unknownSession = CanonicalSession(
        id: "canonical-unknown-model",
        sourceProvider: .claude,
        sourceSessionID: "unknown-model",
        sourcePath: "/tmp/unknown.jsonl",
        title: "Unknown model",
        cwd: "/tmp",
        createdAt: now,
        updatedAt: now,
        model: "other-model",
        contributingProviders: [.claude],
        events: []
    )

    let settings = ModelMappingSettings(
        defaultCodexModel: "codex-default",
        defaultClaudeModel: "claude-default",
        rules: [
            ModelMappingRule(
                sourceProvider: .claude,
                targetProvider: .codex,
                sourcePattern: "claude-sonnet*",
                targetModel: "codex-sonnet-target"
            ),
            ModelMappingRule(
                sourceProvider: .codex,
                targetProvider: .claude,
                sourcePattern: "gpt-5.5*",
                targetModel: "claude-gpt-target"
            )
        ]
    )

    #expect(settings.targetModel(for: claudeSession, targetProvider: .codex) == "codex-sonnet-target")
    #expect(settings.targetModel(for: codexSession, targetProvider: .claude) == "claude-gpt-target")
    #expect(settings.targetModel(for: unknownSession, targetProvider: .codex) == "codex-default")
}

@Test func modelCatalogOverridesFamilyTableAndDistillsAPIJSON() throws {
    // Fictional names only, so parallel tests reading real model names are
    // never affected by this global state.
    defer { ModelCatalog.setContexts([:]) }

    let api = """
    {"testprov": {"models": {"mega-model": {"limit": {"context": 1000000, "input": 900000}}}},
     "anthropic": {"models": {"test-claude-x": {"limit": {"context": 500000}}}}}
    """
    let map = try #require(ModelCatalog.distill(apiJSON: Data(api.utf8)))
    #expect(map["testprov/mega-model"] == 900_000)
    #expect(map["test-claude-x"] == 500_000)

    ModelCatalog.setContexts(map)
    #expect(ModelCatalog.contextTokens(forModel: "testprov/mega-model") == 900_000)
    #expect(ModelCatalog.contextTokens(forModel: "otherprov/mega-model") == 900_000)
    #expect(ModelCatalog.contextTokens(forModel: "test-claude-x") == 500_000)
    #expect(ModelCatalog.contextTokens(forModel: "never-heard-of-it") == nil)
    // Budget derives from catalog data and respects the 2MB cap.
    #expect(transcriptByteBudget(forTargetModel: "testprov/mega-model") == 1_836_000)
    #expect(transcriptByteBudget(forTargetModel: "test-claude-x") == 1_020_000)
}

@Test func transcriptBudgetScalesWithTargetModelContext() throws {
    // Claude 200k, GPT-5.5 272k, unknown providers conservative 128k.
    let claude = transcriptByteBudget(forTargetModel: "claude-sonnet-5")
    let codex = transcriptByteBudget(forTargetModel: "gpt-5.5")
    let opencodeClaude = transcriptByteBudget(forTargetModel: "anthropic/claude-fable-5")
    let unknown = transcriptByteBudget(forTargetModel: "fireworks-ai/accounts/fireworks/models/glm-5p2")

    #expect(claude == opencodeClaude)
    #expect(codex > claude)
    #expect(unknown < claude)
    // Sanity: all within an order of magnitude of the old fixed 300KB.
    #expect(unknown > 150_000 && codex < 700_000)
}

@Test func transcriptWindowKeepsRecentEventsAndDropsOrphanedResults() throws {
    let base = Date(timeIntervalSince1970: 1_783_000_000)
    func event(_ index: Int, role: CanonicalRole = .user, kind: String = "message", text: String, toolID: String? = nil) -> CanonicalEvent {
        CanonicalEvent(
            id: "event-\(index)",
            sourceProvider: .claude,
            sourceEventID: "event-\(index)",
            timestamp: base.addingTimeInterval(Double(index)),
            role: role,
            kind: kind,
            text: text,
            metadata: toolID.map { ["tool_id": .string($0)] } ?? [:]
        )
    }

    let events = [
        event(0, text: String(repeating: "x", count: 500)),
        event(1, role: .tool, kind: "tool_use", text: "call", toolID: "call-1"),
        event(2, role: .tool, kind: "tool_result", text: "result", toolID: "call-1"),
        event(3, role: .tool, kind: "tool_use", text: "call", toolID: "call-2"),
        event(4, role: .tool, kind: "tool_result", text: String(repeating: "y", count: 300), toolID: "call-2"),
        event(5, text: "recent question"),
        event(6, role: .assistant, text: "recent answer")
    ]

    // Budget only fits the last few events; call-1 is trimmed, so its result
    // must be dropped rather than rendered as an orphan.
    let window = transcriptWindow(events, byteBudget: 700)
    #expect(window.events.first?.id != "event-0")
    #expect(window.events.contains { $0.id == "event-6" })
    #expect(window.events.contains { $0.id == "event-5" })
    #expect(!window.events.contains { $0.id == "event-2" })
    if window.events.contains(where: { $0.id == "event-4" }) {
        #expect(window.events.contains { $0.id == "event-3" })
    }
    #expect(window.omitted == events.count - window.events.count)

    // A generous budget keeps everything.
    let full = transcriptWindow(events, byteBudget: 1_000_000)
    #expect(full.events.count == events.count)
    #expect(full.omitted == 0)
}

@Test func multiModelSessionsMapEachAssistantModelSeparately() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("agent-sync-models-\(UUID().uuidString.lowercased())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
    try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)

    let base = Date(timeIntervalSince1970: 1_783_000_601)
    func assistant(_ index: Int, model: String) -> CanonicalEvent {
        CanonicalEvent(
            id: "event-\(index)",
            sourceProvider: .claude,
            sourceEventID: "event-\(index)",
            timestamp: base.addingTimeInterval(Double(index)),
            role: .assistant,
            kind: "message",
            text: "answer \(index)",
            metadata: ["model": .string(model)]
        )
    }
    let session = CanonicalSession(
        id: "canonical-models",
        sourceProvider: .claude,
        sourceSessionID: "models-1",
        sourcePath: "/tmp/models.jsonl",
        title: "Mixed models",
        cwd: root.path,
        createdAt: base,
        updatedAt: base,
        model: "claude-fable-5",
        contributingProviders: [.claude],
        events: [
            assistant(0, model: "claude-fable-5"),
            assistant(1, model: "claude-haiku-4-5"),
            assistant(2, model: "claude-fable-5")
        ]
    )

    let mappings = ModelMappingSettings(
        defaultCodexModel: "gpt-5.5",
        defaultClaudeModel: "claude-sonnet-5",
        rules: [
            ModelMappingRule(sourceProvider: .claude, targetProvider: .codex, sourcePattern: "claude-fable-5", targetModel: "gpt-5.5"),
            ModelMappingRule(sourceProvider: .claude, targetProvider: .codex, sourcePattern: "claude-haiku-4-5", targetModel: "gpt-5-mini")
        ]
    )

    let mirror = try CodexAdapter().render(
        session: session,
        targetSessionID: "44444444-4444-4444-8444-444444444444",
        codexHome: codexHome,
        existingMirror: nil,
        defaultModel: mappings.targetModel(for: session, targetProvider: .codex),
        modelMappings: mappings
    )
    let text = try String(contentsOfFile: mirror.targetPath, encoding: .utf8)

    // Fable turns run under gpt-5.5, the Haiku turn switches to gpt-5-mini and
    // back — recorded as turn_context changes like Codex does natively.
    #expect(text.contains("\"model\":\"gpt-5-mini\""))
    let contextSwitches = text.components(separatedBy: "\"type\":\"turn_context\"").count - 1
    #expect(contextSwitches == 3)
    #expect(!text.contains("claude-haiku-4-5"))
}

@Test func jsonValueDecodesClaudeToolUseResultWithStringStdout() throws {
    let line = """
    {"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]},"toolUseResult":{"stdout":"{\\"nested\\":true}","stderr":"","interrupted":false},"uuid":"tool-result","sessionId":"session-1","timestamp":"2026-07-07T04:45:00.000Z"}
    """
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
    let object = try #require(value.objectValue)
    let toolUseResult = try #require(object.object("toolUseResult"))
    #expect(toolUseResult.string("stdout") == #"{"nested":true}"#)
}

@Test func claudeAskUserQuestionRendersAsVisibleCodexConversation() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("continuo-question-transfer-\(UUID().uuidString.lowercased())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let source = root.appendingPathComponent("11111111-1111-4111-8111-111111111111.jsonl")
    let transcript = #"""
    {"type":"assistant","sessionId":"11111111-1111-4111-8111-111111111111","uuid":"ask-envelope","cwd":"/tmp/project","timestamp":"2026-07-07T11:20:40.691Z","message":{"role":"assistant","model":"claude-fable-5","content":[{"type":"tool_use","id":"toolu_question_1","name":"AskUserQuestion","input":{"questions":[{"question":"What should editing let users change?","header":"Edit scope","multiSelect":false,"options":[{"label":"Timing only","description":"Only timing and thresholds."},{"label":"Full editing","description":"Edit every check field."}]}]}}]}}
    {"type":"user","sessionId":"11111111-1111-4111-8111-111111111111","uuid":"answer-envelope","cwd":"/tmp/project","timestamp":"2026-07-07T11:20:45.691Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_question_1","content":"Your questions have been answered."}]},"toolUseResult":{"questions":[{"question":"What should editing let users change?","header":"Edit scope","multiSelect":false,"options":[{"label":"Timing only","description":"Only timing and thresholds."},{"label":"Full editing","description":"Edit every check field."}]}],"answers":{"What should editing let users change?":"Full editing"},"annotations":{}}}
    """#
    try Data((transcript + "\n").utf8).write(to: source)

    let session = try #require(try ClaudeAdapter().importSession(from: source))
    let question = try #require(session.events.first { $0.kind == "question" })
    let answer = try #require(session.events.first { $0.kind == "answer" })
    #expect(question.role == .assistant)
    #expect(question.text.contains("[Question: Edit scope]"))
    #expect(question.text.contains("Timing only — Only timing and thresholds."))
    #expect(answer.role == .user)
    #expect(answer.text == "[Answer: Edit scope]\nFull editing")

    let codexHome = root.appendingPathComponent("codex", isDirectory: true)
    let mirror = try CodexAdapter().render(
        session: session,
        targetSessionID: "22222222-2222-4222-8222-222222222222",
        codexHome: codexHome,
        existingMirror: nil,
        defaultModel: "gpt-5.5"
    )
    let rendered = try String(contentsOfFile: mirror.targetPath, encoding: .utf8)
    #expect(rendered.contains("[Question: Edit scope]"))
    #expect(rendered.contains("[Answer: Edit scope]"))
    #expect(!rendered.contains("\"name\":\"AskUserQuestion\""))
}

@Test func codexMemoryCitationEnvelopeIsNotRenderedIntoClaude() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("continuo-codex-private-metadata-\(UUID().uuidString.lowercased())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let source = root.appendingPathComponent("11111111-1111-4111-8111-111111111111.jsonl")
    let visibleText = "Fixed and pushed to the draft PR."
    let assistantText = """
    \(visibleText)

    <oai-mem-citation>
    <citation_entries>
    MEMORY.md:215-226|note=[bridge context]
    </citation_entries>
    <rollout_ids>
    019f38eb-90d6-7421-b09f-5dda60de3d37
    </rollout_ids>
    </oai-mem-citation>
    """
    let objects: [[String: JSONValue]] = [
        [
            "type": .string("session_meta"),
            "timestamp": .string("2026-07-11T20:50:00.000Z"),
            "payload": .object([
                "id": .string("11111111-1111-4111-8111-111111111111"),
                "cwd": .string(root.path)
            ])
        ],
        [
            "type": .string("response_item"),
            "timestamp": .string("2026-07-11T20:52:11.817Z"),
            "payload": .object([
                "type": .string("message"),
                "id": .string("assistant-final"),
                "role": .string("assistant"),
                "content": .array([.object([
                    "type": .string("output_text"),
                    "text": .string(assistantText)
                ])])
            ])
        ]
    ]
    try Data(try LineJSON.renderObjects(objects).utf8).write(to: source)

    var session = try #require(try CodexAdapter().importSession(from: source))
    let assistant = try #require(session.events.first { $0.role == .assistant })
    #expect(assistant.text == visibleText)

    // Render-side defense also repairs canonical events cached by an older
    // Continuo build before import-side filtering existed.
    let assistantIndex = try #require(session.events.firstIndex { $0.role == .assistant })
    session.events[assistantIndex].text = assistantText

    let claudeHome = root.appendingPathComponent("claude", isDirectory: true)
    let mirror = try ClaudeAdapter().render(
        session: session,
        targetSessionID: "22222222-2222-4222-8222-222222222222",
        claudeHome: claudeHome,
        existingMirror: nil,
        defaultModel: "claude-fable-5"
    )
    let rendered = try String(contentsOfFile: mirror.targetPath, encoding: .utf8)
    #expect(rendered.contains(visibleText))
    #expect(!rendered.contains("oai-mem-citation"))
    #expect(!rendered.contains("MEMORY.md:215-226"))
}

private func findOnlyCodexSource(in codexHome: URL) -> URL {
    let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
    let paths = (try? FileManager.default.subpathsOfDirectory(atPath: sessions.path)) ?? []
    let jsonl = paths.filter { $0.hasSuffix(".jsonl") }
    return sessions.appendingPathComponent(jsonl[0])
}

private func sqliteThreadCount(_ databaseURL: URL) throws -> Int {
    try Int(sqliteScalar(databaseURL, "select count(*) from threads;")) ?? 0
}

private func sqliteScalar(_ databaseURL: URL, _ sql: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [databaseURL.path, sql]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

private func createMinimalThreadsTable(_ databaseURL: URL) throws {
    let sql = """
    CREATE TABLE threads (
        id TEXT PRIMARY KEY,
        rollout_path TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        source TEXT NOT NULL,
        model_provider TEXT NOT NULL,
        cwd TEXT NOT NULL,
        title TEXT NOT NULL,
        sandbox_policy TEXT NOT NULL,
        approval_mode TEXT NOT NULL,
        tokens_used INTEGER NOT NULL DEFAULT 0,
        has_user_event INTEGER NOT NULL DEFAULT 0,
        archived INTEGER NOT NULL DEFAULT 0,
        archived_at INTEGER,
        git_sha TEXT,
        git_branch TEXT,
        git_origin_url TEXT,
        cli_version TEXT NOT NULL DEFAULT "",
        first_user_message TEXT NOT NULL DEFAULT "",
        agent_nickname TEXT,
        agent_role TEXT,
        memory_mode TEXT NOT NULL DEFAULT "enabled",
        model TEXT,
        reasoning_effort TEXT,
        agent_path TEXT,
        created_at_ms INTEGER,
        updated_at_ms INTEGER,
        thread_source TEXT,
        preview TEXT NOT NULL DEFAULT "",
        recency_at INTEGER NOT NULL DEFAULT 0,
        recency_at_ms INTEGER NOT NULL DEFAULT 0
    );
    """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [databaseURL.path, sql]
    try process.run()
    process.waitUntilExit()
}

private func appendCodexContinuation(
    to url: URL,
    sessionID: String,
    userText: String,
    assistantText: String,
    timestamp: Date
) throws {
    let objects: [[String: JSONValue]] = [
        [
            "type": .string("response_item"),
            "timestamp": .string(DateCoding.render(timestamp)),
            "payload": .object([
                "type": .string("message"),
                "id": .string("codex_native_user_continuation"),
                "role": .string("user"),
                "content": .array([.object([
                    "type": .string("input_text"),
                    "text": .string(userText)
                ])])
            ])
        ],
        [
            "type": .string("response_item"),
            "timestamp": .string(DateCoding.render(timestamp.addingTimeInterval(2))),
            "payload": .object([
                "type": .string("message"),
                "id": .string("codex_native_assistant_continuation"),
                "role": .string("assistant"),
                "content": .array([.object([
                    "type": .string("output_text"),
                    "text": .string(assistantText)
                ])])
            ])
        ]
    ]
    try appendJSONL(objects, to: url)
}

private func appendClaudeContinuation(
    to url: URL,
    sessionID: String,
    cwd: String,
    userText: String,
    assistantText: String,
    timestamp: Date
) throws {
    let userUUID = "claude-native-user-continuation"
    let assistantUUID = "claude-native-assistant-continuation"
    let objects: [[String: JSONValue]] = [
        [
            "type": .string("user"),
            "sessionId": .string(sessionID),
            "uuid": .string(userUUID),
            "parentUuid": .null,
            "timestamp": .string(DateCoding.render(timestamp)),
            "cwd": .string(cwd),
            "userType": .string("external"),
            "version": .string("fixture"),
            "message": .object([
                "role": .string("user"),
                "content": .string(userText)
            ])
        ],
        [
            "type": .string("assistant"),
            "sessionId": .string(sessionID),
            "uuid": .string(assistantUUID),
            "parentUuid": .string(userUUID),
            "timestamp": .string(DateCoding.render(timestamp.addingTimeInterval(2))),
            "cwd": .string(cwd),
            "userType": .string("external"),
            "version": .string("fixture"),
            "message": .object([
                "role": .string("assistant"),
                "type": .string("message"),
                "id": .string("msg_fixture_claude_continuation"),
                "model": .string("claude-fixture"),
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string(assistantText)
                ])])
            ])
        ]
    ]
    try appendJSONL(objects, to: url)
}

private func appendCodexToolEvents(
    to url: URL,
    timestamp: Date
) throws {
    let objects: [[String: JSONValue]] = [
        [
            "type": .string("response_item"),
            "timestamp": .string(DateCoding.render(timestamp)),
            "payload": .object([
                "type": .string("function_call"),
                "id": .string("codex-tool-call-1"),
                "call_id": .string("call_fixture_tool"),
                "name": .string("exec_command"),
                "arguments": .string("{\"cmd\":\"echo hello\"}")
            ])
        ],
        [
            "type": .string("response_item"),
            "timestamp": .string(DateCoding.render(timestamp.addingTimeInterval(1))),
            "payload": .object([
                "type": .string("function_call_output"),
                "call_id": .string("call_fixture_tool"),
                "output": .string("hello\n")
            ])
        ]
    ]
    try appendJSONL(objects, to: url)
}

private func appendJSONL(_ objects: [[String: JSONValue]], to url: URL) throws {
    let text = try LineJSON.renderObjects(objects)
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
    try handle.close()
}

@Test func modelMappingAddsAndStripsOpenCodeProviderPrefixes() throws {
    let settings = ModelMappingSettings(
        defaultCodexModel: "gpt-5.5",
        defaultClaudeModel: "claude-sonnet-5",
        rules: [
            ModelMappingRule(sourceProvider: .codex, targetProvider: .claude, sourcePattern: "gpt-5.5*", targetModel: "claude-fable-5")
        ]
    )

    // Into OpenCode: prefix added, model kept.
    #expect(settings.targetModel(forSourceModel: "claude-fable-5", sourceProvider: .claude, targetProvider: .opencode) == "anthropic/claude-fable-5")
    #expect(settings.targetModel(forSourceModel: "gpt-5.5-codex", sourceProvider: .codex, targetProvider: .opencode) == "openai/gpt-5.5-codex")

    // Out of OpenCode: anthropic models pass through; openai models resolve
    // through the codex→claude rules; unknown providers fall to defaults.
    #expect(settings.targetModel(forSourceModel: "anthropic/claude-opus-4-8", sourceProvider: .opencode, targetProvider: .claude) == "claude-opus-4-8")
    #expect(settings.targetModel(forSourceModel: "openai/gpt-5.5", sourceProvider: .opencode, targetProvider: .claude) == "claude-fable-5")
    #expect(settings.targetModel(forSourceModel: "openai/gpt-5.5", sourceProvider: .opencode, targetProvider: .codex) == "gpt-5.5")
    #expect(settings.targetModel(forSourceModel: "fireworks-ai/accounts/fireworks/models/glm-5p2", sourceProvider: .opencode, targetProvider: .claude) == "claude-sonnet-5")
}

@Test func openCodeAdapterImportsSessionsFromDatabase() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("agent-sync-oc-\(UUID().uuidString.lowercased())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try createOpenCodeFixtureDatabase(root.appendingPathComponent("opencode.db"))

    // Transfer budgets target OpenCode's own most-recent model.
    #expect(OpenCodeAdapter().mostRecentModel(opencodeHome: root) == "anthropic/claude-sonnet-5")

    let session = try #require(try OpenCodeAdapter().importSession(sessionID: "ses_fixture01", opencodeHome: root))
    #expect(session.sourceProvider == .opencode)
    #expect(session.title == "Fixture session")
    #expect(session.cwd == "/tmp/fixture")
    #expect(session.model == "anthropic/claude-sonnet-5")

    #expect(session.events.contains { $0.role == .user && $0.text == "Please list the files." })
    #expect(session.events.contains { $0.role == .assistant && $0.text == "Done — two files found." })
    let toolUse = try #require(session.events.first { $0.kind == "tool_use" })
    #expect(toolUse.metadata.string("tool_id") == "call_fixture_oc")
    #expect(toolUse.metadata.string("tool_op") == "shell.exec")
    let toolResult = try #require(session.events.first { $0.kind == "tool_result" })
    #expect(toolResult.metadata.string("tool_id") == "call_fixture_oc")
    // Assistant events carry their own model for per-message mapping.
    let assistant = try #require(session.events.first { $0.role == .assistant })
    #expect(assistant.metadata.string("model") == "anthropic/claude-sonnet-5")
}

@Test func openCodeExportBuilderProducesImportableShape() throws {
    let base = Date(timeIntervalSince1970: 1_783_000_701)
    let session = CanonicalSession(
        id: "canonical-oc-render",
        sourceProvider: .claude,
        sourceSessionID: "claude-src-1",
        sourcePath: "/tmp/x.jsonl",
        title: "Render me",
        cwd: "/tmp/fixture",
        createdAt: base,
        updatedAt: base.addingTimeInterval(10),
        model: "claude-fable-5",
        contributingProviders: [.claude],
        events: [
            CanonicalEvent(id: "e1", sourceProvider: .claude, sourceEventID: "e1", timestamp: base, role: .user, kind: "message", text: "Fix the bug."),
            CanonicalEvent(id: "e2", sourceProvider: .claude, sourceEventID: "e2", timestamp: base.addingTimeInterval(1), role: .tool, kind: "tool_use", text: "Claude tool use: Bash\n{\"command\":\"ls\"}", metadata: ["tool_name": .string("Bash"), "tool_id": .string("toolu_x"), "tool_op": .string("shell.exec")]),
            CanonicalEvent(id: "e3", sourceProvider: .claude, sourceEventID: "e3", timestamp: base.addingTimeInterval(2), role: .tool, kind: "tool_result", text: "Claude tool result:\nfile.txt", metadata: ["tool_id": .string("toolu_x")]),
            CanonicalEvent(id: "e4", sourceProvider: .claude, sourceEventID: "e4", timestamp: base.addingTimeInterval(3), role: .assistant, kind: "message", text: "Fixed.", metadata: ["model": .string("claude-fable-5")])
        ]
    )

    let built = OpenCodeAdapter().buildExport(
        session: session,
        targetSessionID: "ses_agsynctest01",
        database: nil,
        defaultModel: "anthropic/claude-fable-5",
        modelMappings: ModelMappingSettings()
    )

    let info = try #require(built.export["info"]?.objectValue)
    #expect(info.string("id") == "ses_agsynctest01")
    #expect(info.string("title") == "[Bridge] Render me")
    #expect(info.string("projectID") == "global")

    let messages = try #require(built.export["messages"]?.arrayValue)
    // provenance + user + tool message + assistant
    #expect(messages.count == 4)

    // The tool part carries the opencode tool name and paired call id, with
    // the result folded into the same part's output.
    let toolMessage = try #require(messages.compactMap(\.objectValue).first { message in
        message["parts"]?.arrayValue?.contains { $0.objectValue?.string("type") == "tool" } == true
    })
    let toolPart = try #require(toolMessage["parts"]?.arrayValue?.first?.objectValue)
    #expect(toolPart.string("tool") == "bash")
    #expect(toolPart.string("callID") == "toolu_x")
    let state = try #require(toolPart.object("state"))
    #expect(state.string("output") == "file.txt")

    // Assistant message model got the anthropic/ prefix.
    let assistantMessage = try #require(messages.compactMap(\.objectValue).first { $0.object("info")?.string("role") == "assistant" && $0["parts"]?.arrayValue?.first?.objectValue?.string("type") == "text" })
    #expect(assistantMessage.object("info")?.string("modelID") == "claude-fable-5")
    #expect(assistantMessage.object("info")?.string("providerID") == "anthropic")

    // Echo-guard ids cover every rendered event.
    #expect(built.nativeEventIDs.contains("opencode:ses_agsynctest01:toolu_x"))
    #expect(built.nativeEventIDs.contains("opencode:ses_agsynctest01:toolu_x:output"))
}

private func createOpenCodeFixtureDatabase(_ databaseURL: URL) throws {
    let sql = """
    CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, parent_id TEXT, slug TEXT NOT NULL, directory TEXT NOT NULL, title TEXT NOT NULL, version TEXT NOT NULL, model TEXT, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, time_archived INTEGER);
    CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
    CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
    INSERT INTO session VALUES ('ses_fixture01', 'global', NULL, 'fixture', '/tmp/fixture', 'Fixture session', '1.17.10', '{"providerID":"anthropic","id":"claude-sonnet-5"}', 1783000001000, 1783000021000, NULL);
    INSERT INTO message VALUES ('msg_f1', 'ses_fixture01', 1783000002000, 1783000002000, '{"role":"user","time":{"created":1783000002000},"model":{"providerID":"anthropic","modelID":"claude-sonnet-5"}}');
    INSERT INTO part VALUES ('prt_f1', 'msg_f1', 'ses_fixture01', 1783000002000, 1783000002000, '{"type":"text","text":"Please list the files."}');
    INSERT INTO message VALUES ('msg_f2', 'ses_fixture01', 1783000003000, 1783000003000, '{"role":"assistant","providerID":"anthropic","modelID":"claude-sonnet-5","time":{"created":1783000003000}}');
    INSERT INTO part VALUES ('prt_f2', 'msg_f2', 'ses_fixture01', 1783000003000, 1783000003000, '{"type":"tool","tool":"bash","callID":"call_fixture_oc","state":{"status":"completed","input":{"command":"ls"},"output":"a.txt b.txt","title":"List files"}}');
    INSERT INTO part VALUES ('prt_f3', 'msg_f2', 'ses_fixture01', 1783000004000, 1783000004000, '{"type":"text","text":"Done — two files found."}');
    """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [databaseURL.path, sql]
    try process.run()
    process.waitUntilExit()
}
