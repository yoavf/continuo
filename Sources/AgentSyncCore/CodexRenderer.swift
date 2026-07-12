import Foundation

public extension CodexAdapter {
    func render(
        session: CanonicalSession,
        targetSessionID: String,
        codexHome: URL,
        existingMirror: MirrorRecord?,
        defaultModel: String,
        modelMappings: ModelMappingSettings? = nil
    ) throws -> MirrorRecord {
        try renderReservingOwnership(
            session: session,
            targetSessionID: targetSessionID,
            codexHome: codexHome,
            existingMirror: existingMirror,
            defaultModel: defaultModel,
            modelMappings: modelMappings,
            reserveOwnership: { _ in }
        )
    }

    internal func renderReservingOwnership(
        session: CanonicalSession,
        targetSessionID: String,
        codexHome: URL,
        existingMirror: MirrorRecord?,
        defaultModel: String,
        modelMappings: ModelMappingSettings?,
        reserveOwnership: (MirrorRecord) throws -> Void
    ) throws -> MirrorRecord {
        let now = Date()
        let transcriptURL = PathEncoding.codexSessionPath(
            codexHome: codexHome,
            sessionID: targetSessionID,
            date: session.createdAt
        )
        let rendered = renderJSONL(
            session: session,
            targetSessionID: targetSessionID,
            model: defaultModel,
            modelMappings: modelMappings
        )
        let text = try LineJSON.renderObjects(rendered.objects)
        var mirror = MirrorRecord(
            canonicalSessionID: session.id,
            targetProvider: .codex,
            targetSessionID: targetSessionID,
            targetPath: transcriptURL.path,
            targetIndexPath: nil,
            rendererVersion: 1,
            renderedNativeEventIDs: rendered.nativeEventIDs,
            importedNativeEventIDs: existingMirror?.importedNativeEventIDs ?? [],
            createdAt: existingMirror?.createdAt ?? now,
            updatedAt: now
        )
        try reserveOwnership(mirror)
        try NativeFileWriter.writeAtomically(
            text: text,
            to: transcriptURL,
            replacingExistingBridgeFile: existingMirror?.targetPath == transcriptURL.path,
            allowedRoot: codexHome
        )

        let index = CodexThreadIndex(codexHome: codexHome)
        let indexed = index.upsertThread(
            session: session,
            targetSessionID: targetSessionID,
            rolloutPath: transcriptURL.path,
            model: defaultModel,
            source: "vscode"
        )
        mirror.targetIndexPath = indexed ? index.databaseURL.path : nil
        return mirror
    }

    private func renderJSONL(
        session: CanonicalSession,
        targetSessionID: String,
        model: String,
        modelMappings: ModelMappingSettings?
    ) -> (objects: [[String: JSONValue]], nativeEventIDs: [String]) {
        let start = session.createdAt
        var nativeEventIDs: [String] = []
        var currentModel = model
        // Codex deserializes the first line strictly: base_instructions must be
        // absent (an empty array fails and blocks resume entirely), and
        // turn_context.summary is the "auto"/"concise" preference enum, not
        // prose. Verified against real rollouts and `codex exec resume`.
        var objects: [[String: JSONValue]] = [
            [
                "type": .string("session_meta"),
                "timestamp": .string(DateCoding.render(start)),
                "payload": .object([
                    "id": .string(targetSessionID),
                    "session_id": .string(targetSessionID),
                    "timestamp": .string(DateCoding.render(start)),
                    "cwd": .string(session.cwd),
                    "source": .string("vscode"),
                    "thread_source": .string("user"),
                    "originator": .string("Continuo"),
                    "model_provider": .string("openai"),
                    "cli_version": .string("agent-sync-1")
                ])
            ],
            [
                "type": .string("turn_context"),
                "timestamp": .string(DateCoding.render(start)),
                "payload": .object([
                    "cwd": .string(session.cwd),
                    "model": .string(model),
                    "effort": .string("high"),
                    "approval_policy": .string("untrusted"),
                    "sandbox_policy": .object(["type": .string("workspace-write")]),
                    "workspace_roots": .array([.string(session.cwd)]),
                    "summary": .string("auto")
                ])
            ]
        ]

        let window = transcriptWindow(session.events, byteBudget: transcriptByteBudget(forTargetModel: model))

        // Provenance context travels as a developer message so the resumed
        // agent knows this history was mirrored from the other tool.
        let provenanceID = "agent_sync_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        nativeEventIDs.append("codex:\(targetSessionID):\(provenanceID)")
        objects.append(responseItem(
            timestamp: start,
            payload: [
                "type": .string("message"),
                "id": .string(provenanceID),
                "role": .string("developer"),
                "content": .array([.object([
                    "type": .string("input_text"),
                    "text": .string(bridgeSummary(for: session, targetProvider: .codex, omittedEvents: window.omitted))
                ])])
            ]
        ))

        for event in window.events {
            if isLegacyBridgeContextText(event.text) || isProviderLocalNoise(event.text) {
                continue
            }
            let renderedText = event.role == .assistant ? portableAssistantText(event.text) : event.text
            if renderedText.isEmpty {
                continue
            }
            let nativeMessageID = "agent_sync_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            // Recorded ids must match what CodexAdapter derives on re-import
            // (call_id-based for tool events), or the echo guard misses them.
            switch event.role {
            case .tool:
                let cid = callID(for: event, fallback: nativeMessageID)
                if event.kind == "tool_result" {
                    nativeEventIDs.append("codex:\(targetSessionID):\(cid):output")
                } else {
                    nativeEventIDs.append("codex:\(targetSessionID):\(cid)")
                }
            default:
                nativeEventIDs.append("codex:\(targetSessionID):\(nativeMessageID)")
            }
            switch event.role {
            case .user, .assistant, .developer, .system:
                // A multi-model source session renders as multiple turn
                // contexts, the way Codex itself records model switches.
                if event.role == .assistant {
                    let eventModel = mappedModel(for: event, session: session, target: .codex, mappings: modelMappings, fallback: model)
                    if eventModel != currentModel {
                        currentModel = eventModel
                        objects.append([
                            "type": .string("turn_context"),
                            "timestamp": .string(DateCoding.render(event.timestamp)),
                            "payload": .object([
                                "cwd": .string(session.cwd),
                                "model": .string(eventModel),
                                "effort": .string("high"),
                                "approval_policy": .string("untrusted"),
                                "sandbox_policy": .object(["type": .string("workspace-write")]),
                                "workspace_roots": .array([.string(session.cwd)]),
                                "summary": .string("auto")
                            ])
                        ])
                    }
                }
                let role = codexRole(for: event.role)
                let itemType = event.role == .assistant ? "output_text" : "input_text"
                objects.append(responseItem(
                    timestamp: event.timestamp,
                    payload: [
                        "type": .string("message"),
                        "id": .string(nativeMessageID),
                        "role": .string(role),
                        "content": .array([.object([
                            "type": .string(itemType),
                            "text": .string(renderedText)
                        ])])
                    ]
                ))
                // The TUI transcript is rendered from event_msg display
                // entries, separate from the model-facing response_items —
                // without these the resumed session looks empty.
                if event.role == .assistant {
                    objects.append([
                        "type": .string("event_msg"),
                        "timestamp": .string(DateCoding.render(event.timestamp)),
                        "payload": .object([
                            "type": .string("agent_message"),
                            "message": .string(renderedText)
                        ])
                    ])
                } else if event.role == .user {
                    objects.append([
                        "type": .string("event_msg"),
                        "timestamp": .string(DateCoding.render(event.timestamp)),
                        "payload": .object([
                            "type": .string("user_message"),
                            "message": .string(renderedText),
                            "images": .array([]),
                            "local_images": .array([]),
                            "text_elements": .array([])
                        ])
                    ])
                }
            case .tool:
                objects.append(responseItem(
                    timestamp: event.timestamp,
                    payload: codexToolPayload(for: event, nativeMessageID: nativeMessageID)
                ))
            case .summary:
                objects.append(responseItem(
                    timestamp: event.timestamp,
                    payload: [
                        "type": .string("reasoning"),
                        "id": .string(nativeMessageID),
                        "summary": .array([.object([
                            "type": .string("summary_text"),
                            "text": .string(event.text)
                        ])])
                    ]
                ))
            }
        }
        return (objects, nativeEventIDs)
    }

    private func responseItem(timestamp: Date, payload: [String: JSONValue]) -> [String: JSONValue] {
        [
            "type": .string("response_item"),
            "timestamp": .string(DateCoding.render(timestamp)),
            "payload": .object(payload)
        ]
    }

    private func codexRole(for role: CanonicalRole) -> String {
        switch role {
        case .assistant:
            return "assistant"
        case .developer:
            return "developer"
        case .system:
            return "system"
        case .user, .tool, .summary:
            return "user"
        }
    }

    private func codexToolPayload(for event: CanonicalEvent, nativeMessageID: String) -> [String: JSONValue] {
        switch event.kind {
        case "tool_use":
            let name = ToolTaxonomy.renderedToolName(for: event, target: .codex)
            return [
                "type": .string("function_call"),
                "id": .string(nativeMessageID),
                "call_id": .string(callID(for: event, fallback: nativeMessageID)),
                "name": .string(name),
                "arguments": .string(toolPayloadBody(event.text))
            ]
        case "tool_result":
            return [
                "type": .string("function_call_output"),
                "call_id": .string(callID(for: event, fallback: nativeMessageID)),
                "output": .string(toolPayloadBody(event.text))
            ]
        default:
            return [
                "type": .string("reasoning"),
                "id": .string(nativeMessageID),
                "summary": .array([.object([
                    "type": .string("summary_text"),
                    "text": .string(event.text)
                ])])
            ]
        }
    }

    /// Calls and their outputs must share a call_id or Codex drops the output
    /// as an orphan. The adapters preserve the source pairing in metadata.
    private func callID(for event: CanonicalEvent, fallback: String) -> String {
        if let toolID = event.metadata.string("tool_id") {
            return toolID
        }
        let source = event.sourceEventID
        if source.hasSuffix(":output") {
            return String(source.dropLast(":output".count))
        }
        return fallback
    }
}
