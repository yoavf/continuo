import Foundation

public enum ResumeMode: String, CaseIterable, Sendable {
    /// Full transcript when it fits the context budget, handoff brief when a
    /// full render would have to truncate.
    case auto
    case full
    case handoff
}

/// Builds the compact "handoff" variant of a session: a template-generated
/// brief followed by the most recent user/assistant exchanges, with all tool
/// traffic dropped. No model call involved — the brief is a structured digest.
func handoffSession(from session: CanonicalSession, aiSummary: String? = nil) -> CanonicalSession {
    let messages = session.events.filter {
        $0.kind == "message" && ($0.role == .user || $0.role == .assistant) && !isProviderLocalNoise($0.text)
    }
    let recentCount = 20
    let tail = messages.suffix(recentCount).map { event in
        var trimmed = event
        trimmed.text = boundedTranscriptText(event.text, limit: 4_000)
        return trimmed
    }

    let brief = CanonicalEvent(
        id: "handoff:\(session.id):brief",
        sourceProvider: session.sourceProvider,
        sourceEventID: "handoff-brief",
        timestamp: session.createdAt,
        role: .user,
        kind: "message",
        text: handoffBriefText(for: session, messages: messages, included: tail.count, aiSummary: aiSummary)
    )

    var reduced = session
    reduced.events = [brief] + tail

    // The handoff always ends on the user's most recent request, so the
    // resumed agent is positioned to act on it rather than on its own last
    // reply.
    if let lastUser = messages.last(where: { $0.role == .user }),
       reduced.events.last?.role != .user {
        var reminder = lastUser
        reminder.id = "handoff:\(session.id):latest-request"
        reminder.sourceEventID = "handoff-latest-request"
        reminder.timestamp = session.updatedAt
        reminder.text = "My latest request, repeated so you can continue from it:\n\(boundedTranscriptText(lastUser.text, limit: 4_000))"
        reduced.events.append(reminder)
    }
    return reduced
}

/// Where the untruncated source conversation lives, in a form the resumed
/// agent can read with its own tools.
public func sourceLocationDescription(_ session: CanonicalSession) -> String {
    switch session.sourceProvider {
    case .opencode:
        return "OpenCode session \(session.sourceSessionID) (run `opencode export \(session.sourceSessionID)` from \(session.cwd) to read it)"
    default:
        return session.sourcePath
    }
}

/// Compact digest of a session for an on-device summarizer: user messages and
/// the final assistant reply, capped for a small context window.
public func handoffSummaryInput(for session: CanonicalSession, limit: Int = 12_000) -> String {
    var parts: [String] = []
    for event in session.events where event.kind == "message" && !looksLikeInjectedContext(event.text) {
        switch event.role {
        case .user:
            parts.append("USER: \(boundedTranscriptText(event.text, limit: 600))")
        case .assistant:
            parts.append("ASSISTANT: \(boundedTranscriptText(event.text, limit: 400))")
        default:
            break
        }
    }
    return boundedTranscriptText(parts.joined(separator: "\n"), limit: limit)
}

private func handoffBriefText(
    for session: CanonicalSession,
    messages: [CanonicalEvent],
    included: Int,
    aiSummary: String?
) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"

    let goal = messages.first(where: { $0.role == .user }).map {
        boundedTranscriptText($0.text, limit: 1_200)
    } ?? session.title
    let toolActions = session.events.filter { $0.role == .tool && $0.kind == "tool_use" }.count
    let recentFocus = messages
        .filter { $0.role == .user }
        .suffix(6)
        .map { "- \(boundedTranscriptText($0.text.replacingOccurrences(of: "\n", with: " "), limit: 300))" }
        .joined(separator: "\n")

    let summarySection = aiSummary.map { "\nConversation summary:\n\($0)\n" } ?? ""

    return """
    [Continuo handoff brief]
    This is a compacted continuation of the \(session.sourceProvider.rawValue) conversation "\(session.title)" (session \(session.sourceSessionID)) in \(session.cwd).

    Original goal:
    \(goal)
    \(summarySection)
    History: \(messages.count) messages and \(toolActions) tool actions between \(formatter.string(from: session.createdAt)) and \(formatter.string(from: session.updatedAt)). Only the last \(included) messages follow.
    Full history: \(sourceLocationDescription(session)) — read it directly if you need details older than the messages below.

    Recent focus:
    \(recentFocus.isEmpty ? "- (no recent user messages)" : recentFocus)

    Pick up from the latest exchange below, using the current repository state as ground truth.
    """
}
