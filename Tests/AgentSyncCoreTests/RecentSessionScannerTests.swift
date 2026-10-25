import Foundation
import Testing
@testable import AgentSyncCore

@Suite("Recent session scanner titles")
struct RecentSessionScannerTests {
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
