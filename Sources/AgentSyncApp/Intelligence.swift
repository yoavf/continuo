import AgentSyncCore
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device Apple Intelligence (FoundationModels, macOS 26+). Used for two
/// things, both optional and silently skipped when the model is unavailable:
/// generating readable titles for sessions that only have a raw prompt, and
/// writing the conversation summary inside handoff briefs.
enum Intelligence {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                return true
            }
        }
        #endif
        return false
    }

    static func sessionTitle(from snippet: String) -> String? {
        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 10 else {
            return nil
        }
        let prompt = """
        Write a title of at most 8 words for a coding-assistant conversation that starts with this request. Reply with the title only, no quotes.

        Request:
        \(trimmed)
        """
        guard let title = complete(prompt: prompt, timeout: 10) else {
            return nil
        }
        let cleaned = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
        guard !cleaned.isEmpty, cleaned.count <= 90 else {
            return nil
        }
        return cleaned
    }

    /// Blocking bridge for SyncEngine's summarizer hook; only ever called on a
    /// background thread during prepareResume.
    @Sendable
    static func handoffSummary(for session: CanonicalSession) -> String? {
        guard isAvailable else {
            return nil
        }
        let input = handoffSummaryInput(for: session)
        guard input.count > 200 else {
            return nil
        }
        let prompt = """
        Summarize this coding-assistant conversation in 8-14 terse bullet lines covering: the goal, key decisions and their reasons, concrete artifacts touched (files, features, commands), current state, and open next steps. Keep concrete names; no preamble.

        Conversation:
        \(input)
        """
        return complete(prompt: prompt, timeout: 25)
    }

    private static func complete(prompt: String, timeout: TimeInterval) -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            return nil
        }
        guard case .available = SystemLanguageModel.default.availability else {
            return nil
        }
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            defer { semaphore.signal() }
            do {
                let session = LanguageModelSession()
                let response = try await session.respond(to: prompt)
                box.value = response.content
            } catch {
                // Unavailable/guardrail/context errors all mean "no AI text";
                // callers fall back to heuristics.
            }
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            return nil
        }
        return box.value
        #else
        return nil
        #endif
    }
}

private final class ResultBox: @unchecked Sendable {
    var value: String?
}
