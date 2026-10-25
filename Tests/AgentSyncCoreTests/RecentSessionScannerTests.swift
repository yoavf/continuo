import Foundation
import Testing
@testable import AgentSyncCore

@Suite("Recent session scanner titles")
struct RecentSessionScannerTests {
    @Test("Claude forks keep their own identity and custom title despite copied parent history")
    func claudeForkMetadata() throws {
        try withClaudeProject { root, project in
            let parent = "11111111-1111-4111-8111-111111111111"
            let fork = "22222222-2222-4222-8222-222222222222"
            let history = """
            {"type":"user","sessionId":"\(parent)","cwd":"/tmp/parent","message":{"content":"Original request"}}
            {"type":"custom-title","sessionId":"\(parent)","customTitle":"Parent title"}
            {"type":"assistant","sessionId":"\(parent)","message":{"content":"\(String(repeating: "x", count: 300_000))"}}

            """
            try Data(history.utf8).write(to: project.appendingPathComponent("\(parent).jsonl"))
            let forkURL = project.appendingPathComponent("\(fork).jsonl")
            try Data((history + """
            {"type":"custom-title","sessionId":"\(fork)","customTitle":"Fork title"}
            {"type":"ai-title","sessionId":"\(fork)","aiTitle":"Automatic title"}
            {"type":"user","sessionId":"\(fork)","cwd":"/tmp/fork","message":{"content":"Try a different approach"}}

            """).utf8).write(to: forkURL)
            let previews = try scanClaudeProject(root)
            #expect(previews.count == 2)
            let preview = try #require(previews.first { $0.sessionID == fork })
            #expect(preview.title == "Fork title")
            #expect(preview.hasSourceTitle)
            #expect(preview.cwd == "/tmp/fork")
            let imported = try #require(try ClaudeAdapter().importSession(from: forkURL))
            #expect(imported.sourceSessionID == fork)
            #expect(imported.title == "Fork title")
            #expect(imported.cwd == "/tmp/fork")
        }
    }

    @Test("Claude prompt fallback keeps human text after an injected content block")
    func claudePromptAfterInjectedBlock() throws {
        try withClaudeProject { root, project in
            let id = "11111111-1111-4111-8111-111111111111"
            let url = project.appendingPathComponent("\(id).jsonl")
            let transcript = #"{"type":"user","sessionId":"\#(id)","message":{"content":[{"type":"text","text":"<system-reminder>Worktree context</system-reminder>"},{"type":"text","text":"Fix the session picker"}]}}"# + "\n"
            try Data(transcript.utf8).write(to: url)
            let preview = try #require(try scanClaudeProject(root).first)
            #expect(preview.title == "Fix the session picker")
            #expect(preview.snippet == "Fix the session picker")
            #expect(!preview.hasSourceTitle)
            let imported = try #require(try ClaudeAdapter().importSession(from: url))
            #expect(imported.title == preview.title)
        }
    }

    private func withClaudeProject(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("claude/projects/project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try body(root, project)
    }

    private func scanClaudeProject(_ root: URL) throws -> [SessionPreview] {
        try RecentSessionScanner.scan(
            claudeHome: root.appendingPathComponent("claude"),
            codexHome: root.appendingPathComponent("codex"),
            opencodeHome: root.appendingPathComponent("opencode"),
            lookbackDays: nil,
            maximumPerProvider: 10
        )
    }

    @Test("duplicate Claude transcript copies produce one picker identity")
    func duplicateClaudeTranscriptCopies() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-duplicate-claude-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let claudeHome = root.appendingPathComponent("claude", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex", isDirectory: true)
        let opencodeHome = root.appendingPathComponent("opencode", isDirectory: true)
        let projects = claudeHome.appendingPathComponent("projects", isDirectory: true)
        let firstProject = projects.appendingPathComponent("-tmp-first", isDirectory: true)
        let secondProject = projects.appendingPathComponent("-tmp-second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondProject, withIntermediateDirectories: true)

        let sessionID = "11111111-1111-4111-8111-111111111111"
        let transcript = #"{"sessionId":"\#(sessionID)","cwd":"/tmp/project","type":"user","message":{"role":"user","content":"Visible Claude session"}}"# + "\n"
        try Data(transcript.utf8).write(
            to: firstProject.appendingPathComponent("\(sessionID).jsonl")
        )
        try Data(transcript.utf8).write(
            to: secondProject.appendingPathComponent("\(sessionID).jsonl")
        )

        let otherSessionID = "22222222-2222-4222-8222-222222222222"
        let otherTranscript = #"{"sessionId":"\#(otherSessionID)","cwd":"/tmp/project","type":"user","message":{"role":"user","content":"Another visible Claude session"}}"# + "\n"
        let otherURL = secondProject.appendingPathComponent("\(otherSessionID).jsonl")
        try Data(otherTranscript.utf8).write(to: otherURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -60)],
            ofItemAtPath: otherURL.path
        )

        let previews = try RecentSessionScanner.scan(
            claudeHome: claudeHome,
            codexHome: codexHome,
            opencodeHome: opencodeHome,
            lookbackDays: nil,
            maximumPerProvider: 2
        )

        #expect(previews.count == 2)
        #expect(Set(previews.map(\.id)).count == previews.count)
    }

    @Test("provider title metadata is distinguished from a prompt fallback")
    func sourceTitleProvenance() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-recent-title-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let claudeHome = root.appendingPathComponent("claude", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex", isDirectory: true)
        let opencodeHome = root.appendingPathComponent("opencode", isDirectory: true)
        let claudeProject = claudeHome
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("-tmp-project", isDirectory: true)
        let codexSessions = codexHome
            .appendingPathComponent("sessions/2026/07/27", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexSessions, withIntermediateDirectories: true)

        let claudeID = "11111111-1111-4111-8111-111111111111"
        let claudeLine = #"{"sessionId":"\#(claudeID)","cwd":"/tmp/project","type":"user","message":{"role":"user","content":"Raw Claude prompt"}}"#
        try Data((claudeLine + "\n").utf8).write(
            to: claudeProject.appendingPathComponent("\(claudeID).jsonl")
        )

        let codexID = "22222222-2222-4222-8222-222222222222"
        let codexText = """
        {"type":"session_meta","payload":{"id":"\(codexID)","cwd":"/tmp/project"}}
        {"type":"event_msg","payload":{"type":"user_message","message":"Raw Codex prompt"}}

        """
        try Data(codexText.utf8).write(
            to: codexSessions.appendingPathComponent("rollout-2026-07-27T12-00-00-\(codexID).jsonl")
        )
        try createCodexTitleDatabase(
            at: codexHome.appendingPathComponent("state_5.sqlite"),
            sessionID: codexID,
            title: "Existing Codex title"
        )

        let previews = try RecentSessionScanner.scan(
            claudeHome: claudeHome,
            codexHome: codexHome,
            opencodeHome: opencodeHome,
            lookbackDays: nil,
            maximumPerProvider: 10
        )
        let claude = try #require(previews.first { $0.provider == .claude })
        let codex = try #require(previews.first { $0.provider == .codex })

        #expect(claude.title == "Raw Claude prompt")
        #expect(!claude.hasSourceTitle)
        #expect(codex.title == "Existing Codex title")
        #expect(codex.hasSourceTitle)
    }

    private func createCodexTitleDatabase(
        at databaseURL: URL,
        sessionID: String,
        title: String
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            databaseURL.path,
            """
            CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, updated_at INTEGER);
            INSERT INTO threads VALUES ('\(sessionID)', '\(title)', 1);
            """
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
