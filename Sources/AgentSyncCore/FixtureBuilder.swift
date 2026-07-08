import Foundation

public struct AgentSyncFixtureBuilder {
    public let root: URL
    public let claudeHome: URL
    public let codexHome: URL
    public let stateDirectory: URL
    public let workspace: URL

    public init(root: URL) {
        self.root = root
        self.claudeHome = root.appendingPathComponent("claude-home", isDirectory: true)
        self.codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        self.stateDirectory = root.appendingPathComponent("bridge-state", isDirectory: true)
        self.workspace = root.appendingPathComponent("workspace", isDirectory: true)
    }

    public func create() throws {
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try writeClaudeSourceSession()
        try writeCodexSourceSession()
    }

    public func configuration() -> AgentSyncConfiguration {
        AgentSyncConfiguration(
            claudeHome: claudeHome,
            codexHome: codexHome,
            stateDirectory: stateDirectory,
            defaultCodexModel: "gpt-5.5",
            defaultClaudeModel: "claude-sonnet-5"
        )
    }

    private func writeClaudeSourceSession() throws {
        let sessionID = "11111111-1111-4111-8111-111111111111"
        let projectDir = claudeHome
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(PathEncoding.claudeProjectName(for: workspace.path), isDirectory: true)
        let path = projectDir.appendingPathComponent("\(sessionID).jsonl")
        let start = Date(timeIntervalSince1970: 1_783_000_001)
        let assistant = Date(timeIntervalSince1970: 1_783_000_005)
        let objects: [[String: JSONValue]] = [
            [
                "type": .string("user"),
                "sessionId": .string(sessionID),
                "uuid": .string("claude-user-1"),
                "parentUuid": .null,
                "timestamp": .string(DateCoding.render(start)),
                "cwd": .string(workspace.path),
                "userType": .string("external"),
                "version": .string("fixture"),
                "message": .object([
                    "role": .string("user"),
                    "content": .string("Build a tiny parser in Swift.")
                ])
            ],
            [
                "type": .string("assistant"),
                "sessionId": .string(sessionID),
                "uuid": .string("claude-assistant-1"),
                "parentUuid": .string("claude-user-1"),
                "timestamp": .string(DateCoding.render(assistant)),
                "cwd": .string(workspace.path),
                "userType": .string("external"),
                "version": .string("fixture"),
                "message": .object([
                    "role": .string("assistant"),
                    "type": .string("message"),
                    "id": .string("msg_fixture_claude"),
                    "model": .string("claude-opus-fixture"),
                    "content": .array([.object([
                        "type": .string("text"),
                        "text": .string("I will create the parser and add tests.")
                    ])])
                ])
            ],
            [
                "type": .string("assistant"),
                "sessionId": .string(sessionID),
                "uuid": .string("claude-assistant-2"),
                "parentUuid": .string("claude-assistant-1"),
                "timestamp": .string(DateCoding.render(Date(timeIntervalSince1970: 1_783_000_007))),
                "cwd": .string(workspace.path),
                "userType": .string("external"),
                "version": .string("fixture"),
                "message": .object([
                    "role": .string("assistant"),
                    "type": .string("message"),
                    "id": .string("msg_fixture_claude_tool"),
                    "model": .string("claude-opus-fixture"),
                    "content": .array([.object([
                        "type": .string("tool_use"),
                        "id": .string("toolu_fixture_1"),
                        "name": .string("Bash"),
                        "input": .object(["command": .string("swift --version")])
                    ])])
                ])
            ],
            [
                "type": .string("user"),
                "sessionId": .string(sessionID),
                "uuid": .string("claude-user-2"),
                "parentUuid": .string("claude-assistant-2"),
                "timestamp": .string(DateCoding.render(Date(timeIntervalSince1970: 1_783_000_009))),
                "cwd": .string(workspace.path),
                "userType": .string("external"),
                "version": .string("fixture"),
                "message": .object([
                    "role": .string("user"),
                    "content": .array([.object([
                        "type": .string("tool_result"),
                        "tool_use_id": .string("toolu_fixture_1"),
                        "content": .string("Swift version 6.3")
                    ])])
                ])
            ],
            [
                "type": .string("ai-title"),
                "sessionId": .string(sessionID),
                "aiTitle": .string("Build Swift parser")
            ]
        ]
        try NativeFileWriter.writeAtomically(
            text: try LineJSON.renderObjects(objects),
            to: path,
            replacingExistingBridgeFile: false,
            allowedRoot: claudeHome
        )
    }

    private func writeCodexSourceSession() throws {
        let sessionID = "22222222-2222-4222-8222-222222222222"
        let start = Date(timeIntervalSince1970: 1_783_000_101)
        let path = PathEncoding.codexSessionPath(codexHome: codexHome, sessionID: sessionID, date: start)
        let objects: [[String: JSONValue]] = [
            [
                "type": .string("session_meta"),
                "timestamp": .string(DateCoding.render(start)),
                "payload": .object([
                    "id": .string(sessionID),
                    "session_id": .string(sessionID),
                    "timestamp": .string(DateCoding.render(start)),
                    "cwd": .string(workspace.path),
                    "source": .string("fixture"),
                    "originator": .string("Fixture"),
                    "model_provider": .string("openai"),
                    "cli_version": .string("fixture")
                ])
            ],
            [
                "type": .string("turn_context"),
                "timestamp": .string(DateCoding.render(start)),
                "payload": .object([
                    "cwd": .string(workspace.path),
                    "model": .string("gpt-fixture"),
                    "effort": .string("high")
                ])
            ],
            [
                "type": .string("response_item"),
                "timestamp": .string(DateCoding.render(start)),
                "payload": .object([
                    "type": .string("message"),
                    "id": .string("codex-user-1"),
                    "role": .string("user"),
                    "content": .array([.object([
                        "type": .string("input_text"),
                        "text": .string("Port this shell script to Swift.")
                    ])])
                ])
            ],
            [
                "type": .string("event_msg"),
                "timestamp": .string(DateCoding.render(start)),
                "payload": .object([
                    "type": .string("user_message"),
                    "message": .string("Port this shell script to Swift."),
                    "images": .array([]),
                    "local_images": .array([]),
                    "text_elements": .array([])
                ])
            ],
            [
                "type": .string("response_item"),
                "timestamp": .string(DateCoding.render(Date(timeIntervalSince1970: 1_783_000_107))),
                "payload": .object([
                    "type": .string("message"),
                    "id": .string("codex-assistant-1"),
                    "role": .string("assistant"),
                    "content": .array([.object([
                        "type": .string("output_text"),
                        "text": .string("I will inspect the script and preserve behavior.")
                    ])])
                ])
            ]
        ]
        try NativeFileWriter.writeAtomically(
            text: try LineJSON.renderObjects(objects),
            to: path,
            replacingExistingBridgeFile: false,
            allowedRoot: codexHome
        )
    }
}
