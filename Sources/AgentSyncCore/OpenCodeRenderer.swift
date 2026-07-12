import Foundation

public extension OpenCodeAdapter {
    /// Writes the mirror through OpenCode's own supported ingestion path:
    /// build an `opencode export`-shaped JSON document and run
    /// `opencode import`. Import upserts by the embedded session id; when
    /// rewriting an owned mirror the old session row is deleted first so no
    /// stale messages survive.
    func render(
        session: CanonicalSession,
        targetSessionID: String,
        opencodeHome: URL,
        existingMirror: MirrorRecord?,
        defaultModel: String,
        modelMappings: ModelMappingSettings? = nil,
        budgetModel explicitBudgetModel: String? = nil
    ) throws -> MirrorRecord {
        try renderReservingOwnership(
            session: session,
            targetSessionID: targetSessionID,
            opencodeHome: opencodeHome,
            existingMirror: existingMirror,
            defaultModel: defaultModel,
            modelMappings: modelMappings,
            budgetModel: explicitBudgetModel,
            reserveOwnership: { _ in }
        )
    }

    internal func renderReservingOwnership(
        session: CanonicalSession,
        targetSessionID: String,
        opencodeHome: URL,
        existingMirror: MirrorRecord?,
        defaultModel: String,
        modelMappings: ModelMappingSettings?,
        budgetModel explicitBudgetModel: String?,
        reserveOwnership: (MirrorRecord) throws -> Void
    ) throws -> MirrorRecord {
        let now = Date()
        let database = Self.databaseURL(opencodeHome: opencodeHome)
        guard FileManager.default.fileExists(atPath: database.path) else {
            throw AgentSyncError.commandFailed("OpenCode database not found at \(database.path) — has OpenCode run at least once?")
        }

        let built = buildExport(
            session: session,
            targetSessionID: targetSessionID,
            database: database,
            defaultModel: defaultModel,
            modelMappings: modelMappings,
            budgetModel: explicitBudgetModel ?? mostRecentModel(opencodeHome: opencodeHome) ?? defaultModel
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(JSONValue.object(built.export))
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-sync-opencode-\(targetSessionID).json")
        try data.write(to: tempURL, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let mirror = MirrorRecord(
            canonicalSessionID: session.id,
            targetProvider: .opencode,
            targetSessionID: targetSessionID,
            targetPath: "opencode://\(targetSessionID)",
            targetIndexPath: database.path,
            rendererVersion: 1,
            renderedNativeEventIDs: built.nativeEventIDs,
            importedNativeEventIDs: existingMirror?.importedNativeEventIDs ?? [],
            createdAt: existingMirror?.createdAt ?? now,
            updatedAt: now
        )
        try reserveOwnership(mirror)

        if existingMirror != nil {
            // Bridge-owned session: clear it so import can't leave stale rows.
            try OpenCodeSQL.execute(
                database: database,
                sql: "DELETE FROM session WHERE id = \(OpenCodeSQL.quote(targetSessionID));"
            )
        }
        try Self.runImport(file: tempURL, expectedSessionID: targetSessionID, workingDirectory: session.cwd)

        return mirror
    }

    func buildExport(
        session: CanonicalSession,
        targetSessionID: String,
        database: URL?,
        defaultModel: String,
        modelMappings: ModelMappingSettings?,
        budgetModel: String? = nil
    ) -> (export: [String: JSONValue], nativeEventIDs: [String]) {
        // Tested empirically: OpenCode does NOT compact an oversized imported
        // history on first send — the provider just errors. Budget against the
        // model OpenCode will actually run (its most recent), not the mapped
        // metadata model, which it ignores on resume.
        let window = transcriptWindow(
            session.events,
            byteBudget: transcriptByteBudget(forTargetModel: budgetModel ?? defaultModel)
        )
        var nativeEventIDs: [String] = []
        var messages: [JSONValue] = []
        var toolPartLocation: [String: (message: Int, part: Int)] = [:]
        var messageCounter = 0
        var previousMessageID: String?

        func millis(_ date: Date) -> JSONValue {
            .number((date.timeIntervalSince1970 * 1000).rounded())
        }

        func modelPieces(_ reference: String) -> (provider: String, id: String) {
            if let slash = reference.firstIndex(of: "/") {
                return (String(reference[..<slash]), String(reference[reference.index(after: slash)...]))
            }
            return ("anthropic", reference)
        }

        func newMessageID() -> String {
            messageCounter += 1
            let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(18)
            return "msg_agsync\(String(format: "%03d", messageCounter))\(suffix)"
        }

        func appendMessage(role: String, model: String, timestamp: Date, parts rawParts: [JSONValue]) -> (id: String, index: Int) {
            let id = newMessageID()
            let pieces = modelPieces(model)
            // Import requires every part to carry its own identifiers.
            let parts: [JSONValue] = rawParts.enumerated().map { index, value in
                guard case .object(var part) = value else {
                    return value
                }
                part["id"] = .string("prt_\(id.dropFirst(4))p\(index)")
                part["messageID"] = .string(id)
                part["sessionID"] = .string(targetSessionID)
                return .object(part)
            }
            var info: [String: JSONValue] = [
                "id": .string(id),
                "sessionID": .string(targetSessionID),
                "role": .string(role),
                "agent": .string("build"),
                "time": .object(["created": millis(timestamp)])
            ]
            if role == "assistant" {
                info["parentID"] = .string(previousMessageID ?? id)
                info["providerID"] = .string(pieces.provider)
                info["modelID"] = .string(pieces.id)
                info["mode"] = .string("build")
                info["finish"] = .string("stop")
                info["path"] = .object([
                    "cwd": .string(session.cwd),
                    "root": .string(session.cwd)
                ])
                info["cost"] = .number(0)
                info["tokens"] = .object([
                    "total": .number(0), "input": .number(0), "output": .number(0),
                    "reasoning": .number(0),
                    "cache": .object(["read": .number(0), "write": .number(0)])
                ])
            } else {
                info["model"] = .object([
                    "providerID": .string(pieces.provider),
                    "modelID": .string(pieces.id)
                ])
                info["summary"] = .object(["diffs": .array([])])
            }
            messages.append(.object(["info": .object(info), "parts": .array(parts)]))
            previousMessageID = id
            return (id, messages.count - 1)
        }

        // Provenance first, so the resumed agent knows where this came from.
        let provenance = appendMessage(
            role: "user",
            model: defaultModel,
            timestamp: session.createdAt,
            parts: [.object(["type": .string("text"), "text": .string(bridgeSummary(for: session, targetProvider: .opencode, omittedEvents: window.omitted))])]
        )
        nativeEventIDs.append("opencode:\(targetSessionID):\(provenance.id):0")

        for event in window.events {
            if isLegacyBridgeContextText(event.text) || isProviderLocalNoise(event.text) {
                continue
            }
            let renderedText = event.role == .assistant ? portableAssistantText(event.text) : event.text
            if renderedText.isEmpty {
                continue
            }
            switch event.role {
            case .user, .developer, .system:
                let message = appendMessage(
                    role: "user",
                    model: defaultModel,
                    timestamp: event.timestamp,
                    parts: [.object(["type": .string("text"), "text": .string(renderedText)])]
                )
                nativeEventIDs.append("opencode:\(targetSessionID):\(message.id):0")
            case .assistant:
                let model = mappedModel(for: event, session: session, target: .opencode, mappings: modelMappings, fallback: defaultModel)
                let message = appendMessage(
                    role: "assistant",
                    model: model,
                    timestamp: event.timestamp,
                    parts: [.object(["type": .string("text"), "text": .string(renderedText)])]
                )
                nativeEventIDs.append("opencode:\(targetSessionID):\(message.id):0")
            case .summary:
                let message = appendMessage(
                    role: "assistant",
                    model: defaultModel,
                    timestamp: event.timestamp,
                    parts: [.object(["type": .string("reasoning"), "text": .string(event.text)])]
                )
                nativeEventIDs.append("opencode:\(targetSessionID):\(message.id):reasoning:0")
            case .tool:
                let callID = toolCallID(for: event)
                if event.kind == "tool_use" {
                    let toolName = ToolTaxonomy.renderedToolName(for: event, target: .opencode)
                    let startMS = (event.timestamp.timeIntervalSince1970 * 1000).rounded()
                    let part: [String: JSONValue] = [
                        "type": .string("tool"),
                        "tool": .string(toolName),
                        "callID": .string(callID),
                        "state": .object([
                            "status": .string("completed"),
                            "input": toolInputValue(from: event.text),
                            "output": .string(""),
                            "title": .string(toolName),
                            "metadata": .object([:]),
                            "time": .object(["start": .number(startMS), "end": .number(startMS)])
                        ])
                    ]
                    let message = appendMessage(
                        role: "assistant",
                        model: mappedModel(for: event, session: session, target: .opencode, mappings: modelMappings, fallback: defaultModel),
                        timestamp: event.timestamp,
                        parts: [.object(part)]
                    )
                    toolPartLocation[callID] = (message.index, 0)
                    nativeEventIDs.append("opencode:\(targetSessionID):\(callID)")
                } else if event.kind == "tool_result" {
                    nativeEventIDs.append("opencode:\(targetSessionID):\(callID):output")
                    guard let location = toolPartLocation[callID],
                          case .object(var message) = messages[location.message],
                          case .array(var parts) = message["parts"] ?? .null,
                          case .object(var part) = parts[location.part],
                          case .object(var state) = part["state"] ?? .null else {
                        continue
                    }
                    state["output"] = .string(toolPayloadBody(event.text))
                    part["state"] = .object(state)
                    parts[location.part] = .object(part)
                    message["parts"] = .array(parts)
                    messages[location.message] = .object(message)
                }
            }
        }

        let info: [String: JSONValue] = [
            "id": .string(targetSessionID),
            "slug": .string("agent-sync-\(String(targetSessionID.suffix(8)))"),
            "projectID": .string(projectID(for: session.cwd, database: database)),
            "directory": .string(session.cwd),
            "title": .string("[Bridge] \(session.title)"),
            "version": .string(installedVersion(database: database)),
            "time": .object([
                "created": millis(session.createdAt),
                "updated": millis(session.updatedAt)
            ])
        ]

        return (["info": .object(info), "messages": .array(messages)], nativeEventIDs)
    }

    private func toolCallID(for event: CanonicalEvent) -> String {
        if let toolID = event.metadata.string("tool_id") {
            return toolID
        }
        let source = event.sourceEventID
        if source.hasSuffix(":output") {
            return String(source.dropLast(":output".count))
        }
        return source.replacingOccurrences(of: ":", with: "_")
    }

    private func toolInputValue(from text: String) -> JSONValue {
        let body = toolPayloadBody(text)
        if let object = OpenCodeAdapter.jsonObject(body) {
            return .object(object)
        }
        return .object(["raw": .string(body)])
    }

    private func projectID(for cwd: String, database: URL?) -> String {
        guard let database else {
            return "global"
        }
        let rows = (try? OpenCodeSQL.query(
            database: database,
            sql: "SELECT id FROM project WHERE worktree = \(OpenCodeSQL.quote(cwd)) LIMIT 1;"
        )) ?? []
        return rows.first?.string("id") ?? "global"
    }

    private func installedVersion(database: URL?) -> String {
        guard let database else {
            return "1.17.0"
        }
        let rows = (try? OpenCodeSQL.query(
            database: database,
            sql: "SELECT version FROM session ORDER BY time_updated DESC LIMIT 1;"
        )) ?? []
        return rows.first?.string("version") ?? "1.17.0"
    }

    static func executableURL() -> URL? {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".opencode/bin/opencode"),
            URL(fileURLWithPath: "/usr/local/bin/opencode"),
            URL(fileURLWithPath: "/opt/homebrew/bin/opencode")
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func runImport(file: URL, expectedSessionID: String, workingDirectory: String) throws {
        guard let executable = executableURL() else {
            throw AgentSyncError.commandFailed("opencode CLI not found (looked in ~/.opencode/bin and /usr/local/bin).")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["import", file.path]
        // App-spawned processes get a bare PATH; give the CLI a real one.
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = "\(home)/.opencode/bin:/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        // Import stamps the session's directory/project from the process cwd.
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory), isDirectory.boolValue {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errors = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let combined = String(data: output + errors, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0, combined.contains(expectedSessionID) else {
            throw AgentSyncError.commandFailed("opencode import failed: \(combined.suffix(300))")
        }
    }
}

extension OpenCodeSQL {
    static func execute(database: URL, sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        // sqlite3 disables foreign-key enforcement by default. OpenCode uses
        // cascades to remove transcript rows when a session is replaced.
        process.arguments = ["-cmd", "PRAGMA foreign_keys = ON", database.path, sql]
        let stderr = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderr
        try process.run()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AgentSyncError.commandFailed(String(data: errorData, encoding: .utf8) ?? "sqlite3 failed")
        }
    }
}
