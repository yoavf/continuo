import AgentSyncCore
import Foundation
import Testing
@testable import AgentSyncApp

@Suite("Recent session titles")
struct SessionTitleTests {
    @Test("source title wins over a cached generated title")
    func sourceTitleWins() {
        let item = SessionItem(
            preview: preview(title: "Existing Codex title", hasSourceTitle: true),
            mirrorOrigin: nil,
            refinedTitle: "Generated replacement"
        )

        #expect(item.displayTitle == "Existing Codex title")
        #expect(!item.wantsRefinedTitle)
    }

    @Test("a missing source title requests generation")
    func missingSourceTitleRequestsGeneration() {
        let item = SessionItem(
            preview: preview(title: "Raw first prompt", hasSourceTitle: false),
            mirrorOrigin: nil,
            refinedTitle: nil
        )

        #expect(item.displayTitle == "Raw first prompt")
        #expect(item.wantsRefinedTitle)
    }

    @Test("Continuo and legacy bridge prefixes stay hidden in the picker")
    func bridgePrefixesAreHidden() {
        let current = SessionItem(
            preview: preview(title: "[Continuo] Converted title", hasSourceTitle: true),
            mirrorOrigin: .claude,
            refinedTitle: nil
        )
        let legacy = SessionItem(
            preview: preview(title: "[Bridge] Converted title", hasSourceTitle: true),
            mirrorOrigin: .claude,
            refinedTitle: nil
        )

        #expect(current.displayTitle == "Converted title")
        #expect(legacy.displayTitle == "Converted title")
    }

    private func preview(title: String, hasSourceTitle: Bool) -> SessionPreview {
        SessionPreview(
            provider: .codex,
            sessionID: "session-id",
            path: "/tmp/session.jsonl",
            title: title,
            hasSourceTitle: hasSourceTitle,
            snippet: "Raw first prompt",
            models: [],
            estimatedTokens: 0,
            cwd: "/tmp",
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
