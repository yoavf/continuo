import Foundation

public extension ClaudeAdapter {
    func render(
        session: CanonicalSession,
        targetSessionID: String,
        claudeHome: URL,
        existingMirror: MirrorRecord?,
        defaultModel: String,
        modelMappings: ModelMappingSettings? = nil
    ) throws -> MirrorRecord {
        let now = Date()
        let projectName = PathEncoding.claudeProjectName(for: session.cwd)
        let transcriptURL = claudeHome
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectName, isDirectory: true)
            .appendingPathComponent("\(targetSessionID).jsonl")

        let rendered = renderJSONL(
            session: session,
            targetSessionID: targetSessionID,
            model: defaultModel,
            modelMappings: modelMappings
        )
        let text = try LineJSON.renderObjects(rendered.objects)
        try NativeFileWriter.writeAtomically(
            text: text,
            to: transcriptURL,
            replacingExistingBridgeFile: existingMirror?.targetPath == transcriptURL.path,
            allowedRoot: claudeHome
        )

        return MirrorRecord(
            canonicalSessionID: session.id,
            targetProvider: .claude,
            targetSessionID: targetSessionID,
            targetPath: transcriptURL.path,
            targetIndexPath: nil,
            rendererVersion: 1,
            renderedNativeEventIDs: rendered.nativeEventIDs,
            importedNativeEventIDs: existingMirror?.importedNativeEventIDs ?? [],
            createdAt: existingMirror?.createdAt ?? now,
            updatedAt: now
        )
    }

    private func renderJSONL(
        session: CanonicalSession,
        targetSessionID: String,
        model: String,
        modelMappings: ModelMappingSettings?
    ) -> (objects: [[String: JSONValue]], nativeEventIDs: [String]) {
        var objects: [[String: JSONValue]] = []
        var nativeEventIDs: [String] = []
        var parentUUID: String?
        let start = session.createdAt
        let summaryUUID = UUID().uuidString.lowercased()
        let window = transcriptWindow(session.events, byteBudget: transcriptByteBudget(forTargetModel: model))

        objects.append([
            "type": .string("summary"),
            "sessionId": .string(targetSessionID),
            "summary": .string(bridgeSummary(for: session, targetProvider: .claude, omittedEvents: window.omitted)),
            "cwd": .string(session.cwd),
            "timestamp": .string(DateCoding.render(start)),
            "uuid": .string(summaryUUID),
            "parentUuid": .null,
            "userType": .string("external"),
            "version": .string("agent-sync-1")
        ])
        parentUUID = summaryUUID

        for event in window.events {
            if isLegacyBridgeContextText(event.text) || isProviderLocalNoise(event.text) {
                continue
            }
            let renderedText = event.role == .assistant ? portableAssistantText(event.text) : event.text
            if renderedText.isEmpty {
                continue
            }
            let uuid = UUID().uuidString.lowercased()
            switch event.role {
            case .assistant:
                nativeEventIDs.append("claude:\(targetSessionID):\(uuid):text:0")
                objects.append(claudeMessageObject(
                    type: "assistant",
                    role: "assistant",
                    content: .array([.object(["type": .string("text"), "text": .string(renderedText)])]),
                    uuid: uuid,
                    parentUUID: parentUUID,
                    sessionID: targetSessionID,
                    cwd: session.cwd,
                    timestamp: event.timestamp,
                    model: mappedModel(for: event, session: session, target: .claude, mappings: modelMappings, fallback: model)
                ))
                parentUUID = uuid
            case .user:
                nativeEventIDs.append("claude:\(targetSessionID):\(uuid)")
                objects.append(claudeMessageObject(
                    type: "user",
                    role: "user",
                    content: .string(renderedText),
                    uuid: uuid,
                    parentUUID: parentUUID,
                    sessionID: targetSessionID,
                    cwd: session.cwd,
                    timestamp: event.timestamp,
                    model: nil
                ))
                parentUUID = uuid
            case .tool:
                let rendered = claudeToolObject(
                    event: event,
                    uuid: uuid,
                    parentUUID: parentUUID,
                    sessionID: targetSessionID,
                    cwd: session.cwd,
                    timestamp: event.timestamp,
                    model: model
                )
                nativeEventIDs.append(rendered.nativeEventID)
                objects.append(rendered.object)
                parentUUID = uuid
            case .summary:
                nativeEventIDs.append("claude:\(targetSessionID):\(uuid):summary")
                objects.append([
                    "type": .string("summary"),
                    "sessionId": .string(targetSessionID),
                    "summary": .string(event.text),
                    "cwd": .string(session.cwd),
                    "timestamp": .string(DateCoding.render(event.timestamp)),
                    "uuid": .string(uuid),
                    "parentUuid": parentUUID.map(JSONValue.string) ?? .null,
                    "userType": .string("external"),
                    "version": .string("agent-sync-1")
                ])
            case .developer, .system:
                continue
            }
        }

        objects.append([
            "type": .string("ai-title"),
            "sessionId": .string(targetSessionID),
            "aiTitle": .string("[Bridge] \(session.title)")
        ])
        objects.append([
            "type": .string("last-prompt"),
            "sessionId": .string(targetSessionID),
            "leafUuid": .string(parentUUID ?? ""),
            "lastPrompt": .string(session.events.last(where: { $0.role == .user })?.text ?? session.title)
        ])
        return (objects, nativeEventIDs)
    }

    private func claudeToolObject(
        event: CanonicalEvent,
        uuid: String,
        parentUUID: String?,
        sessionID: String,
        cwd: String,
        timestamp: Date,
        model: String
    ) -> (object: [String: JSONValue], nativeEventID: String) {
        switch event.kind {
        case "tool_use":
            let name = ToolTaxonomy.renderedToolName(for: event, target: .claude)
            let toolID = claudeToolID(from: event, fallback: uuid)
            return (
                claudeMessageObject(
                    type: "assistant",
                    role: "assistant",
                    content: .array([.object([
                        "type": .string("tool_use"),
                        "id": .string(toolID),
                        "name": .string(name),
                        "input": toolInputObject(from: event.text)
                    ])]),
                    uuid: uuid,
                    parentUUID: parentUUID,
                    sessionID: sessionID,
                    cwd: cwd,
                    timestamp: timestamp,
                    model: model
                ),
                // Must match ClaudeAdapter's derived id (":tool-use:") or the
                // echo guard misses this event on re-import.
                "claude:\(sessionID):\(uuid):tool-use:0"
            )
        case "tool_result":
            let toolID = claudeToolResultID(from: event, fallback: uuid)
            return (
                claudeMessageObject(
                    type: "user",
                    role: "user",
                    content: .array([.object([
                        "type": .string("tool_result"),
                        "tool_use_id": .string(toolID),
                        "content": .string(toolPayloadBody(event.text)),
                        "is_error": .bool(false)
                    ])]),
                    uuid: uuid,
                    parentUUID: parentUUID,
                    sessionID: sessionID,
                    cwd: cwd,
                    timestamp: timestamp,
                    model: nil
                ),
                "claude:\(sessionID):\(uuid):tool-result:0"
            )
        default:
            return (
                [
                    "type": .string("summary"),
                    "sessionId": .string(sessionID),
                    "summary": .string(event.text),
                    "cwd": .string(cwd),
                    "timestamp": .string(DateCoding.render(timestamp)),
                    "uuid": .string(uuid),
                    "parentUuid": parentUUID.map(JSONValue.string) ?? .null,
                    "userType": .string("external"),
                    "version": .string("agent-sync-1")
                ],
                "claude:\(sessionID):\(uuid):tool_summary"
            )
        }
    }

    /// The Anthropic API requires tool_use.input to be a JSON object.
    private func toolInputObject(from text: String) -> JSONValue {
        let body = toolPayloadBody(text)
        if let foundation = try? JSONSerialization.jsonObject(with: Data(body.utf8)),
           let value = try? JSONValue.foundation(foundation),
           case .object = value {
            return value
        }
        return .object(["raw": .string(body)])
    }

    // Calls and results must share an id or the pairing is lost on resume.
    // The adapters preserve the source pairing in metadata; the fallbacks
    // derive it from codex-style ":output" event ids.
    private func claudeToolID(from event: CanonicalEvent, fallback: String) -> String {
        if let toolID = event.metadata.string("tool_id") {
            return toolID
        }
        let raw = event.sourceEventID
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "-", with: "_")
        return raw.isEmpty ? "agent_sync_tool_\(fallback)" : "agent_sync_tool_\(raw)"
    }

    private func claudeToolResultID(from event: CanonicalEvent, fallback: String) -> String {
        if let toolID = event.metadata.string("tool_id") {
            return toolID
        }
        let source = event.sourceEventID
        if source.hasSuffix(":output") {
            let base = String(source.dropLast(":output".count))
            let raw = base
                .replacingOccurrences(of: ":", with: "_")
                .replacingOccurrences(of: "-", with: "_")
            return "agent_sync_tool_\(raw)"
        }
        return claudeToolID(from: event, fallback: fallback)
    }

    private func claudeMessageObject(
        type: String,
        role: String,
        content: JSONValue,
        uuid: String,
        parentUUID: String?,
        sessionID: String,
        cwd: String,
        timestamp: Date,
        model: String?
    ) -> [String: JSONValue] {
        var message: [String: JSONValue] = [
            "role": .string(role),
            "content": content
        ]
        if role == "assistant" {
            message["type"] = .string("message")
            message["id"] = .string("agent_sync_\(uuid.replacingOccurrences(of: "-", with: ""))")
            message["model"] = .string(model ?? "agent-sync")
            message["stop_reason"] = .string("end_turn")
            message["stop_sequence"] = .null
            message["usage"] = .object([:])
        }

        return [
            "type": .string(type),
            "sessionId": .string(sessionID),
            "uuid": .string(uuid),
            "parentUuid": parentUUID.map(JSONValue.string) ?? .null,
            "timestamp": .string(DateCoding.render(timestamp)),
            "cwd": .string(cwd),
            "userType": .string("external"),
            "version": .string("agent-sync-1"),
            "isSidechain": .bool(false),
            "entrypoint": .string("agent-sync"),
            "message": .object(message)
        ]
    }

}
