import Foundation

func boundedTranscriptText(_ text: String, limit: Int = 20_000) -> String {
    guard text.count > limit else {
        return text
    }

    let omitted = text.count - limit
    return """
    \(text.prefix(limit))

    [Continuo truncated \(omitted) characters from this large transcript payload.]
    """
}

/// Codex appends this machine-readable envelope to some assistant responses so
/// its own UI can attribute memory use. It is not part of the conversation and
/// has no meaning in another provider, so only remove a complete trailing
/// envelope with the expected schema. Quoted or partial tags remain untouched.
func portableAssistantText(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let openingTag = "<oai-mem-citation>"
    let closingTag = "</oai-mem-citation>"
    guard trimmed.hasSuffix(closingTag),
          let opening = trimmed.range(of: openingTag, options: .backwards) else {
        return text
    }

    let envelope = trimmed[opening.lowerBound...]
    guard envelope.contains("<citation_entries>"),
          envelope.contains("</citation_entries>"),
          envelope.contains("<rollout_ids>"),
          envelope.contains("</rollout_ids>") else {
        return text
    }

    return String(trimmed[..<opening.lowerBound])
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Two events with the same role, kind, timestamp, and text are the same turn
/// regardless of which render minted their IDs. This is the dedupe key that
/// keeps import/render round-trips from ever accumulating duplicates.
public func eventContentKey(_ event: CanonicalEvent) -> String {
    "\(event.role.rawValue)|\(event.kind)|\(event.timestamp.timeIntervalSince1970)|\(event.text)"
}

public func dedupeEventsByContent(_ events: [CanonicalEvent]) -> [CanonicalEvent] {
    var seen = Set<String>()
    return events.filter { seen.insert(eventContentKey($0)).inserted }
}

/// Usable input tokens for a model: exact numbers from the models.dev catalog
/// when cached, else a conservative family table. Unknown models get 128k so a
/// wrong guess degrades to extra truncation, not a failed resume.
func contextTokens(forModel model: String) -> Int {
    let name = model.lowercased()
    // Codex CLI enforces ~400k regardless of the API model's larger raw
    // window (observed: a ~550k-token render died with "ran out of room").
    let cap = (name.contains("gpt-") || name.contains("codex")) ? 400_000 : Int.max
    if let exact = ModelCatalog.contextTokens(forModel: model) {
        return min(exact, cap)
    }
    if name.contains("claude") {
        return 200_000
    }
    if name.contains("gpt-5") || name.contains("codex") {
        return min(272_000, cap)
    }
    return 131_072
}

/// Whether a conversation of this estimated size transfers whole to the given
/// target model, or gets trimmed/handed off. Drives UI labeling.
public func fullTranscriptFits(estimatedTokens: Int, targetModel: String) -> Bool {
    Int(Double(estimatedTokens) * 3.4) <= transcriptByteBudget(forTargetModel: targetModel)
}

/// Byte budget for a render aimed at `targetModel`: 60% of the context window
/// (the rest is headroom for system prompt, tools, and the agent's actual
/// work), at ~3.4 chars/token — calibrated against a real resume, where a
/// ~300KB render measured 111k tokens in Codex.
public func transcriptByteBudget(forTargetModel targetModel: String) -> Int {
    let usableTokens = Int(Double(contextTokens(forModel: targetModel)) * 0.6)
    // Cap even for 1M+ context models: past ~2MB the transplant cost (load
    // time, attention quality) outweighs marginal old history.
    return min(Int(Double(usableTokens) * 3.4), 2_000_000)
}

/// A transcript larger than the target model's context window makes the
/// mirrored session unresumable, so renders keep the most recent events that
/// fit a byte budget. Tool results whose call was trimmed away are dropped too
/// — the target would discard them as orphans anyway.
func transcriptWindow(
    _ events: [CanonicalEvent],
    byteBudget: Int = 300_000
) -> (events: [CanonicalEvent], omitted: Int) {
    var total = 0
    var kept: [CanonicalEvent] = []
    for event in events.reversed() {
        total += event.text.utf8.count + 64
        if total > byteBudget, !kept.isEmpty {
            break
        }
        kept.append(event)
    }
    kept.reverse()

    var availableCalls = Set<String>()
    kept = kept.filter { event in
        guard event.role == .tool, let key = toolPairKey(event) else {
            return true
        }
        if event.kind == "tool_result" {
            return availableCalls.contains(key)
        }
        availableCalls.insert(key)
        return true
    }
    return (kept, events.count - kept.count)
}

/// Adapters store tool events as "<human prefix>\n<payload>"; renderers want
/// just the payload (the JSON args or the raw output).
func toolPayloadBody(_ text: String) -> String {
    if let range = text.range(of: "\n") {
        return String(text[range.upperBound...])
    }
    return text
}

func toolPairKey(_ event: CanonicalEvent) -> String? {
    guard event.role == .tool else {
        return nil
    }
    if let toolID = event.metadata.string("tool_id") {
        return toolID
    }
    let source = event.sourceEventID
    if event.kind == "tool_result", source.hasSuffix(":output") {
        return String(source.dropLast(":output".count))
    }
    return source
}

/// Provider-local machinery with no meaning to another agent: slash-command
/// invocations and their stdout ("/effort", "/model"…), and harness-injected
/// instruction blocks the target regenerates natively. Omitted from mirrors
/// entirely.
public func isProviderLocalNoise(_ text: String) -> Bool {
    let prefixes = [
        "<command-name", "<command-message", "<command-args",
        "<local-command-stdout", "<local-command-stderr", "<local-command-caveat",
        "<task-notification", "<bash-input", "<bash-stdout", "<bash-stderr",
        "<system-reminder", "<environment_context", "<user_instructions",
        "# AGENTS.md", "<INSTRUCTIONS"
    ]
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let exactMessages = [
        "Continue from where you left off.",
        "No response requested."
    ]
    return exactMessages.contains(trimmed)
        || prefixes.contains { trimmed.hasPrefix($0) }
}

/// Anything that must never become a session title or "goal": provider-local
/// noise plus our own bridge markers.
public func looksLikeInjectedContext(_ text: String) -> Bool {
    if isProviderLocalNoise(text) {
        return true
    }
    let prefixes = [
        "Caveat:", "[Continuo handoff brief]", "Continuo mirrored this conversation"
    ]
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return prefixes.contains { trimmed.hasPrefix($0) }
}

func isLegacyBridgeContextText(_ text: String) -> Bool {
    text.hasPrefix("[Tool context from ")
        || text.hasPrefix("[Developer context from ")
        || text.hasPrefix("[System context from ")
        || text.hasPrefix("[Summary from ")
}
