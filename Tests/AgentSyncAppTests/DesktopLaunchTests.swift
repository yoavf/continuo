import Testing
@testable import AgentSyncApp

@Suite("Desktop session launching")
struct DesktopLaunchTests {
    @Test("Codex desktop sessions use the documented task deep link")
    func codexDesktopDeepLink() throws {
        let url = try #require(TerminalLauncher.codexDesktopURL(sessionID: "thread-123"))
        #expect(url.absoluteString == "codex://threads/thread-123")
    }

    @Test("Claude Desktop imports a Claude Code session through its resume deep link")
    func claudeDesktopDeepLink() throws {
        let url = try #require(
            TerminalLauncher.claudeDesktopURL(
                sessionID: "11111111-2222-4333-8444-555555555555"
            )
        )
        #expect(
            url.absoluteString
                == "claude://resume?session=11111111-2222-4333-8444-555555555555"
        )
    }
}
