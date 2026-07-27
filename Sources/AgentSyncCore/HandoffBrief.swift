import Foundation

public enum ResumeMode: String, CaseIterable, Sendable {
    /// Legacy CLI/default value: full transcript when it fits, handoff when it
    /// does not. The app UI presents concrete outcomes instead.
    case auto
    case full
    case bookends
    case handoff
}

/// Keeps the beginning and end of the human conversation while dropping the
/// large, noisy middle: every tool call/result and older middle exchange.
func bookendSession(from session: CanonicalSession) -> CanonicalSession {
    let messages = session.events.filter {
        $0.kind == "message" && ($0.role == .user || $0.role == .assistant) && !isProviderLocalNoise($0.text)
    }
    let openingCount = 4
    let recentCount = 8
    let opening = Array(messages.prefix(openingCount))
    let openingIDs = Set(opening.map(\.id))
    let recent = messages.suffix(recentCount).filter { !openingIDs.contains($0.id) }
    let selected = (opening + recent).map { event in
        var trimmed = event
        trimmed.text = boundedTranscriptText(event.text, limit: 4_000)
        return trimmed
    }
    let keptSourceMessages = opening.count + recent.count
    let omittedMessages = max(0, messages.count - keptSourceMessages)
    let toolEvents = session.events.filter { $0.role == .tool }.count
    let notice = CanonicalEvent(
        id: "bookends:\(session.id):notice",
        sourceProvider: session.sourceProvider,
        sourceEventID: "bookends-notice",
        timestamp: session.createdAt,
        role: .user,
        kind: "message",
        text: """
        [Continuo transcript bookends]
        This continuation keeps the first \(opening.count) and latest \(recent.count) conversation messages from "\(session.title)".
        It omits \(omittedMessages) middle conversation messages and \(toolEvents) tool call/result events.
        Full history: \(sourceLocationDescription(session)).
        Continue from the latest exchange below, using the current repository state as ground truth.
        """
    )

    var reduced = session
    reduced.events = [notice] + selected
    appendLatestRequestIfNeeded(to: &reduced, messages: messages, idPrefix: "bookends")
    return reduced
}

/// Builds the compact "handoff" variant of a session: a template-generated
/// brief followed by the most recent user/assistant exchanges, with all tool
/// traffic dropped. No model call involved — the brief is a structured digest.
func handoffSession(from session: CanonicalSession, aiSummary: String? = nil) -> CanonicalSession {
    let messages = session.events.filter {
        $0.kind == "message" && ($0.role == .user || $0.role == .assistant) && !isProviderLocalNoise($0.text)
    }
    let recentCount = 8
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
    appendLatestRequestIfNeeded(to: &reduced, messages: messages, idPrefix: "handoff")
    return reduced
}

private func appendLatestRequestIfNeeded(
    to reduced: inout CanonicalSession,
    messages: [CanonicalEvent],
    idPrefix: String
) {
    if let lastUser = messages.last(where: { $0.role == .user }),
       reduced.events.last?.role != .user {
        var reminder = lastUser
        reminder.id = "\(idPrefix):\(reduced.id):latest-request"
        reminder.sourceEventID = "\(idPrefix)-latest-request"
        reminder.timestamp = reduced.updatedAt
        reminder.text = "My latest request, repeated so you can continue from it:\n\(boundedTranscriptText(lastUser.text, limit: 4_000))"
        reduced.events.append(reminder)
    }
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

/// Compact, evenly sampled digest for the on-device summarizer. Sampling
/// across the whole thread is more faithful than filling the small context
/// window from the beginning and silently losing the ending.
public func handoffSummaryInput(for session: CanonicalSession, limit: Int = 12_000) -> String {
    let messages = session.events.filter {
        $0.kind == "message"
            && ($0.role == .user || $0.role == .assistant)
            && !looksLikeInjectedContext($0.text)
    }
    let maximumEntries = 50
    let sampled: [CanonicalEvent]
    if messages.count <= maximumEntries {
        sampled = messages
    } else {
        let step = Double(messages.count - 1) / Double(maximumEntries - 1)
        let indices = (0..<maximumEntries).map { Int((Double($0) * step).rounded()) }
        sampled = indices.map { messages[$0] }
    }
    let entryLimit = max(120, min(500, limit / max(1, sampled.count) - 16))
    var parts: [String] = []
    for event in sampled {
        switch event.role {
        case .user:
            parts.append("USER: \(boundedTranscriptText(event.text, limit: entryLimit))")
        case .assistant:
            parts.append("ASSISTANT: \(boundedTranscriptText(event.text, limit: entryLimit))")
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
