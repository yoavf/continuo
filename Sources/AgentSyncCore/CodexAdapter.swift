import Foundation

public struct CodexAdapter: Sendable {
    public init() {}

    public func importSessions(
        from codexHome: URL,
        lookbackDays: Int? = nil,
        maximumSessions: Int? = nil
    ) throws -> [CanonicalSession] {
        let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sessions.path) else {
            return []
        }

        let files = try discoverJSONLSessionFiles(
            under: sessions,
            lookbackDays: lookbackDays,
            maximumSessions: maximumSessions
        )

        return try files.compactMap { try importSession(from: $0) }
    }

    public func importSession(from url: URL) throws -> CanonicalSession? {
        let objects = try LineJSON.readObjects(from: url)
        guard !objects.isEmpty else {
            return nil
        }

        var sessionID = codexSessionIDFromFilename(url) ?? UUID().uuidString.lowercased()
        var cwd = ""
        var model: String?
        var title: String?
        var createdAt: Date?
        var updatedAt: Date?
        var events: [CanonicalEvent] = []

        for (index, object) in objects.enumerated() {
            let timestamp = DateCoding.parse(object.string("timestamp")) ?? createdAt ?? Date(timeIntervalSince1970: 0)
            if createdAt == nil {
                createdAt = timestamp
            }
            updatedAt = timestamp

            guard let type = object.string("type") else {
                continue
            }

            if type == "session_meta", let payload = object.object("payload") {
                sessionID = payload.string("session_id") ?? payload.string("id") ?? sessionID
                cwd = payload.string("cwd") ?? cwd
            }

            if type == "turn_context", let payload = object.object("payload") {
                cwd = payload.string("cwd") ?? cwd
                model = payload.string("model") ?? model
            }

            // The typed user prompt arrives as an event_msg, separate from the
            // instruction-stuffed response_item stream — best title source.
            if type == "event_msg",
               title == nil,
               let payload = object.object("payload"),
               payload.string("type") == "user_message",
               let message = payload.string("message"),
               !looksLikeInjectedContext(message) {
                title = message
            }

            guard type == "response_item", let payload = object.object("payload") else {
                continue
            }

            let payloadType = payload.string("type") ?? ""
            switch payloadType {
            case "message":
                guard let roleString = payload.string("role") else {
                    continue
                }
                let role = canonicalRole(fromCodexRole: roleString)
                let extractedText = extractCodexMessageText(payload)
                let portableText = role == .assistant ? portableAssistantText(extractedText) : extractedText
                let text = boundedTranscriptText(portableText, limit: 60_000)
                guard !text.isEmpty, role == .assistant || !isProviderLocalNoise(text) else {
                    continue
                }
                let eventID = payload.string("id") ?? "message:\(index)"
                var metadata: [String: JSONValue] = [:]
                if role == .assistant, let model {
                    // The active model comes from the preceding turn_context.
                    metadata["model"] = .string(model)
                }
                events.append(CanonicalEvent(
                    id: "codex:\(sessionID):\(eventID)",
                    sourceProvider: .codex,
                    sourceEventID: eventID,
                    timestamp: timestamp,
                    role: role,
                    kind: "message",
                    text: text,
                    metadata: metadata
                ))
                if title == nil, role == .user, !looksLikeInjectedContext(text) {
                    title = text
                }
            case "function_call", "custom_tool_call":
                let name = payload.string("name") ?? "function_call"
                let arguments = boundedTranscriptText(
                    payload.string("arguments")
                        ?? payload.string("input")
                        ?? payload["arguments"]?.prettyString()
                        ?? payload["input"]?.prettyString()
                        ?? "",
                    limit: 12_000
                )
                let eventID = payload.string("call_id") ?? payload.string("id") ?? "function_call:\(index)"
                var metadata: [String: JSONValue] = ["tool_name": .string(name)]
                if let callID = payload.string("call_id") {
                    metadata["tool_id"] = .string(callID)
                }
                if let operation = ToolTaxonomy.universalOperation(provider: .codex, toolName: name) {
                    metadata["tool_op"] = .string(operation)
                }
                events.append(CanonicalEvent(
                    id: "codex:\(sessionID):\(eventID)",
                    sourceProvider: .codex,
                    sourceEventID: eventID,
                    timestamp: timestamp,
                    role: .tool,
                    kind: "tool_use",
                    text: "Codex tool call: \(name)\n\(arguments)",
                    metadata: metadata
                ))
            case "function_call_output", "custom_tool_call_output":
                let output = boundedTranscriptText(
                    payload.string("output") ?? payload["output"]?.prettyString() ?? "",
                    limit: 20_000
                )
                let eventID = payload.string("call_id") ?? "function_call_output:\(index)"
                var metadata: [String: JSONValue] = [:]
                if let callID = payload.string("call_id") {
                    metadata["tool_id"] = .string(callID)
                }
                events.append(CanonicalEvent(
                    id: "codex:\(sessionID):\(eventID):output",
                    sourceProvider: .codex,
                    sourceEventID: "\(eventID):output",
                    timestamp: timestamp,
                    role: .tool,
                    kind: "tool_result",
                    text: "Codex tool output:\n\(output)",
                    metadata: metadata
                ))
            case "reasoning":
                if let summary = payload.array("summary"), !summary.isEmpty {
                    let text = boundedTranscriptText(
                        summary.map { $0.prettyString() }.joined(separator: "\n"),
                        limit: 20_000
                    )
                    let eventID = payload.string("id") ?? "reasoning:\(index)"
                    events.append(CanonicalEvent(
                        id: "codex:\(sessionID):\(eventID)",
                        sourceProvider: .codex,
                        sourceEventID: eventID,
                        timestamp: timestamp,
                        role: .summary,
                        kind: "reasoning_summary",
                        text: text
                    ))
                }
            default:
                continue
            }
        }

        guard !events.isEmpty else {
            return nil
        }

        if cwd.isEmpty {
            cwd = FileManager.default.currentDirectoryPath
        }

        return CanonicalSession(
            id: UUID().uuidString.lowercased(),
            sourceProvider: .codex,
            sourceSessionID: sessionID,
            sourcePath: url.path,
            title: cleanTitle(title) ?? "Codex session \(sessionID)",
            cwd: cwd,
            createdAt: createdAt ?? events.first?.timestamp ?? Date(),
            updatedAt: updatedAt ?? events.last?.timestamp ?? Date(),
            model: model,
            contributingProviders: [.codex],
            events: events
        )
    }
}

private func canonicalRole(fromCodexRole role: String) -> CanonicalRole {
    switch role {
    case "assistant":
        return .assistant
    case "developer":
        return .developer
    case "system":
        return .system
    default:
        return .user
    }
}

private func extractCodexMessageText(_ payload: [String: JSONValue]) -> String {
    guard let content = payload["content"] else {
        return ""
    }

    switch content {
    case .string(let text):
        return text
    case .array(let values):
        return values.compactMap { item in
            guard let object = item.objectValue else {
                return nil
            }
            return object.string("text")
                ?? object.string("content")
                ?? object["input"]?.prettyString()
        }.joined(separator: "\n")
    default:
        return ""
    }
}
