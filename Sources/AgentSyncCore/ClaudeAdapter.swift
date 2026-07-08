import Foundation

public struct ClaudeAdapter: Sendable {
    public init() {}

    public func importSessions(
        from claudeHome: URL,
        lookbackDays: Int? = nil,
        maximumSessions: Int? = nil
    ) throws -> [CanonicalSession] {
        let projects = claudeHome.appendingPathComponent("projects", isDirectory: true)
        guard FileManager.default.fileExists(atPath: projects.path) else {
            return []
        }

        // Subagent transcripts live under <session>/subagents/ and are not
        // resumable sessions of their own.
        let files = try discoverJSONLSessionFiles(
            under: projects,
            lookbackDays: lookbackDays,
            maximumSessions: maximumSessions,
            excludingPathComponents: ["subagents"]
        )

        return try files.compactMap { try importSession(from: $0) }
    }

    public func importSession(from url: URL) throws -> CanonicalSession? {
        let objects = try LineJSON.readObjects(from: url)
        guard !objects.isEmpty else {
            return nil
        }

        let fallbackSessionID = url.deletingPathExtension().lastPathComponent
        var sessionID = fallbackSessionID
        var cwd = ""
        var title: String?
        var model: String?
        var firstTimestamp: Date?
        var lastTimestamp: Date?
        var events: [CanonicalEvent] = []

        for (index, object) in objects.enumerated() {
            if let value = object.string("sessionId") {
                sessionID = value
            }
            if cwd.isEmpty, let value = object.string("cwd") {
                cwd = value
            }
            // ai-title lines recur as Claude re-titles the session; latest wins.
            if let aiTitle = object.string("aiTitle") {
                title = aiTitle
            }

            let timestamp = DateCoding.parse(object.string("timestamp")) ?? firstTimestamp ?? Date(timeIntervalSince1970: 0)
            if firstTimestamp == nil, object.string("timestamp") != nil {
                firstTimestamp = timestamp
            }
            if object.string("timestamp") != nil {
                lastTimestamp = timestamp
            }

            guard let type = object.string("type") else {
                continue
            }

            if let message = object.object("message"),
               (type == "user" || type == "assistant") {
                if model == nil {
                    model = message.string("model")
                }
                events.append(contentsOf: extractEvents(
                    message: message,
                    envelope: object,
                    type: type,
                    index: index,
                    sessionID: sessionID,
                    timestamp: timestamp
                ))
            }
        }

        guard !events.isEmpty else {
            return nil
        }

        if cwd.isEmpty {
            cwd = url.deletingLastPathComponent().lastPathComponent
        }

        let createdAt = firstTimestamp ?? events.first?.timestamp ?? Date()
        let updatedAt = lastTimestamp ?? events.last?.timestamp ?? createdAt
        let resolvedTitle = cleanTitle(title)
            ?? cleanTitle(events.first(where: { $0.role == .user && !looksLikeInjectedContext($0.text) })?.text)
            ?? "Claude session \(sessionID)"

        return CanonicalSession(
            id: UUID().uuidString.lowercased(),
            sourceProvider: .claude,
            sourceSessionID: sessionID,
            sourcePath: url.path,
            title: resolvedTitle,
            cwd: cwd,
            createdAt: createdAt,
            updatedAt: updatedAt,
            model: model,
            contributingProviders: [.claude],
            events: events
        )
    }

    private func extractEvents(
        message: [String: JSONValue],
        envelope: [String: JSONValue],
        type: String,
        index: Int,
        sessionID: String,
        timestamp: Date
    ) -> [CanonicalEvent] {
        let uuid = envelope.string("uuid") ?? "\(sessionID):\(index)"
        let baseID = "claude:\(sessionID):\(uuid)"
        let role: CanonicalRole = type == "assistant" ? .assistant : .user
        guard let content = message["content"] else {
            return []
        }

        // A session can span several models (e.g. Fable for main turns, Haiku
        // for quick ones); each assistant event remembers its own.
        var messageMetadata: [String: JSONValue] = [:]
        if role == .assistant, let eventModel = message.string("model") {
            messageMetadata["model"] = .string(eventModel)
        }

        switch content {
        case .string(let text):
            guard !isProviderLocalNoise(text) else {
                return []
            }
            return [CanonicalEvent(
                id: baseID,
                sourceProvider: .claude,
                sourceEventID: uuid,
                timestamp: timestamp,
                role: role,
                kind: "message",
                text: boundedTranscriptText(text, limit: 60_000),
                metadata: messageMetadata
            )]
        case .array(let values):
            return values.enumerated().compactMap { itemIndex, value in
                guard let item = value.objectValue else {
                    return nil
                }
                let itemType = item.string("type") ?? "unknown"
                switch itemType {
                case "text":
                    guard let text = item.string("text"), !text.isEmpty, !isProviderLocalNoise(text) else {
                        return nil
                    }
                    return CanonicalEvent(
                        id: "\(baseID):text:\(itemIndex)",
                        sourceProvider: .claude,
                        sourceEventID: "\(uuid):text:\(itemIndex)",
                        timestamp: timestamp,
                        role: role,
                        kind: "message",
                        text: boundedTranscriptText(text, limit: 60_000),
                        metadata: messageMetadata
                    )
                case "tool_use":
                    let name = item.string("name") ?? "tool"
                    let input = boundedTranscriptText(item["input"]?.prettyString() ?? "", limit: 12_000)
                    var metadata: [String: JSONValue] = ["tool_name": .string(name)]
                    // The native block id pairs this call with its result;
                    // renderers must reuse it so targets don't see orphans.
                    if let toolID = item.string("id") {
                        metadata["tool_id"] = .string(toolID)
                    }
                    if let operation = ToolTaxonomy.universalOperation(provider: .claude, toolName: name) {
                        metadata["tool_op"] = .string(operation)
                    }
                    return CanonicalEvent(
                        id: "\(baseID):tool-use:\(itemIndex)",
                        sourceProvider: .claude,
                        sourceEventID: "\(uuid):tool-use:\(itemIndex)",
                        timestamp: timestamp,
                        role: .tool,
                        kind: "tool_use",
                        text: "Claude tool use: \(name)\n\(input)",
                        metadata: metadata
                    )
                case "tool_result":
                    let result = boundedTranscriptText(item["content"]?.prettyString() ?? "", limit: 20_000)
                    var metadata: [String: JSONValue] = [:]
                    if let toolID = item.string("tool_use_id") {
                        metadata["tool_id"] = .string(toolID)
                    }
                    return CanonicalEvent(
                        id: "\(baseID):tool-result:\(itemIndex)",
                        sourceProvider: .claude,
                        sourceEventID: "\(uuid):tool-result:\(itemIndex)",
                        timestamp: timestamp,
                        role: .tool,
                        kind: "tool_result",
                        text: "Claude tool result:\n\(result)",
                        metadata: metadata
                    )
                default:
                    return nil
                }
            }
        default:
            return []
        }
    }
}

func cleanTitle(_ text: String?) -> String? {
    guard let text else {
        return nil
    }
    let collapsed = text
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !collapsed.isEmpty else {
        return nil
    }
    return String(collapsed.prefix(90))
}

func bridgeSummary(for session: CanonicalSession, targetProvider: AgentKind, omittedEvents: Int = 0) -> String {
    var summary = """
    Continuo mirrored this conversation from \(session.sourceProvider.rawValue) into \(targetProvider.rawValue).

    Original title: \(session.title)
    Original cwd: \(session.cwd)
    Original session id: \(session.sourceSessionID)

    Hidden reasoning and provider-private runtime state are not portable. Continue from the visible transcript, tool summaries, and current repository state.
    """
    if omittedEvents > 0 {
        summary += "\n\nTo fit the context window, the \(omittedEvents) oldest events were omitted from this mirror. The full history lives in the original \(session.sourceProvider.rawValue) session."
    }
    return summary
}

/// Per-event model resolution: an assistant event carries the model that
/// actually produced it; cross-provider events go through the mapping table,
/// same-provider events keep their original model.
func mappedModel(
    for event: CanonicalEvent,
    session: CanonicalSession,
    target: AgentKind,
    mappings: ModelMappingSettings?,
    fallback: String
) -> String {
    let sourceModel = event.metadata.string("model") ?? session.model
    if event.sourceProvider == target {
        return sourceModel ?? fallback
    }
    guard let mappings else {
        return fallback
    }
    return mappings.targetModel(forSourceModel: sourceModel, sourceProvider: event.sourceProvider, targetProvider: target)
}

