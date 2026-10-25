import Foundation
import Testing
@testable import AgentSyncCore

@Suite("Recent session scanner titles")
struct RecentSessionScannerTests {
    @Test("Claude title cache reuses missing titles and invalidates on size, modification time, and path")
    func claudeTitleCacheInvalidation() throws {
        try withClaudeProject { _, project in
            let cache = ClaudeTitleCache()
            let url = project.appendingPathComponent("session.jsonl")
            let date = Date(timeIntervalSince1970: 1_000)
            try Data("a".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            var reads = 0
            var recovered: String?
            func read(_ file: URL) throws -> String? {
                try cache.title(for: file, sessionID: "session") {
                    reads += 1
                    return recovered
                }
            }
            #expect(try read(url) == nil)
            #expect(try read(url) == nil)
            #expect(reads == 1)

            recovered = "Added title"
            try Data("ab".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            #expect(try read(url) == "Added title")
            #expect(reads == 2)

            recovered = "Renamed title"
            try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(1)], ofItemAtPath: url.path)
            #expect(try read(url) == "Renamed title")
            #expect(try read(url) == "Renamed title")
            #expect(reads == 3)

            let copy = project.appendingPathComponent("copy.jsonl")
            try FileManager.default.copyItem(at: url, to: copy)
            #expect(try read(copy) == "Renamed title")
            #expect(reads == 4)
        }
    }

    @Test("Claude title cache retries failed reads and files that changed while being scanned")
    func claudeTitleCacheUnstableReads() throws {
        try withClaudeProject { _, project in
            let cache = ClaudeTitleCache()
            let url = project.appendingPathComponent("session.jsonl")
            try Data("a".utf8).write(to: url)
            var reads = 0
            enum ReadError: Error { case failed }
            do {
                _ = try cache.title(for: url, sessionID: "session") { throw ReadError.failed }
                Issue.record("Expected the read to fail")
            } catch ReadError.failed {}
            let first = try cache.title(for: url, sessionID: "session") {
                reads += 1
                try Data("ab".utf8).write(to: url)
                return "Stale title"
            }
            #expect(first == "Stale title")
            let second = try cache.title(for: url, sessionID: "session") {
                reads += 1
                return "Current title"
            }
            #expect(second == "Current title")
            #expect(reads == 2)
        }
    }

    @Test("Claude custom titles in skipped middle records override edge automatic titles")
    func claudeTitleInMiddle() throws {
        try withClaudeProject { root, project in
            let id = "11111111-1111-4111-8111-111111111111"
            let url = project.appendingPathComponent("\(id).jsonl")
            let filler = #"{"type":"assistant","message":{"content":"\#(String(repeating: "x", count: 2000))"}}"# + "\n"
            let transcript = """
            {"type":"user","sessionId":"\(id)","message":{"content":"Original request"}}
            {"type":"ai-title","sessionId":"\(id)","aiTitle":"Automatic title"}

            """ + String(repeating: filler, count: 180) + """
            {"type":"custom-title","sessionId":"\(id)","customTitle":"Old explicit title"}
            {"type":"assistant","message":{"content":"\(String(repeating: "x", count: 300_000))"}}
            {"type":"custom-title","sessionId":"\(id)","customTitle":"Latest explicit title"}

            """ + String(repeating: filler, count: 180)
            try Data(transcript.utf8).write(to: url)
            let preview = try #require(try scanClaudeProject(root).first)
            let imported = try #require(try ClaudeAdapter().importSession(from: url))
            #expect(preview.title == "Latest explicit title")
            #expect(preview.hasSourceTitle)
            #expect(preview.title == imported.title)
        }
    }

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

    @Test("edge reads survive a byte cut inside a multibyte character")
    func edgeReadsSurviveMultibyteCut() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-multibyte-edge-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let claudeHome = root.appendingPathComponent("claude", isDirectory: true)
        let project = claudeHome
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("-tmp-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        // "é" is two UTF-8 bytes. Pad the lines around a long run of them so
        // both the 256 KB prefix cut and the 256 KB tail cut land mid-character.
        let edgeBytes = 256 * 1024
        let sessionID = "33333333-3333-4333-8333-333333333333"
        var header = #"{"sessionId":"\#(sessionID)","cwd":"/tmp/project","type":"user","message":{"role":"user","content":"Multibyte prompt"}}"# + "\n"
        header += #"{"type":"progress","text":""#
        if (edgeBytes - header.utf8.count).isMultiple(of: 2) {
            header = header.replacingOccurrences(of: #"{"type":"progress""#, with: #"{ "type":"progress""#)
        }
        var titleLine = #"{"type":"ai-title","aiTitle":"Title from the tail"}"# + "\n"
        if (3 + titleLine.utf8.count).isMultiple(of: 2) {
            titleLine = " " + titleLine
        }
        let transcript = header + String(repeating: "é", count: 300_000) + "\"}\n" + titleLine
        try Data(transcript.utf8).write(to: project.appendingPathComponent("\(sessionID).jsonl"))

        let previews = try RecentSessionScanner.scan(
            claudeHome: claudeHome,
            codexHome: root.appendingPathComponent("codex", isDirectory: true),
            opencodeHome: root.appendingPathComponent("opencode", isDirectory: true),
            lookbackDays: nil,
            maximumPerProvider: 10
        )
        let preview = try #require(previews.first)

        #expect(preview.snippet == "Multibyte prompt")
        #expect(preview.title == "Title from the tail")
        #expect(preview.cwd == "/tmp/project")
    }

    @Test("a small transcript keeps its first record in the tail read")
    func smallTranscriptTailKeepsFirstRecord() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-small-tail-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let claudeHome = root.appendingPathComponent("claude", isDirectory: true)
        let project = claudeHome
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("-tmp-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let sessionID = "44444444-4444-4444-8444-444444444444"
        let transcript = #"{"type":"assistant","sessionId":"\#(sessionID)","cwd":"/tmp/project","message":{"role":"assistant","content":"hi","usage":{"input_tokens":1234}}}"# + "\n"
        try Data(transcript.utf8).write(to: project.appendingPathComponent("\(sessionID).jsonl"))

        let previews = try RecentSessionScanner.scan(
            claudeHome: claudeHome,
            codexHome: root.appendingPathComponent("codex", isDirectory: true),
            opencodeHome: root.appendingPathComponent("opencode", isDirectory: true),
            lookbackDays: nil,
            maximumPerProvider: 10
        )

        #expect(try #require(previews.first).estimatedTokens == 1234)
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
