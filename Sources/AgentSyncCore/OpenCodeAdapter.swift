import Foundation

/// OpenCode (v1.17+) keeps sessions in `opencode.db`: `session` rows plus
/// `message`/`part` rows whose `data` columns hold JSON. Reads go straight to
/// sqlite; writes go through OpenCode's own supported path, `opencode import`.
/// A session is addressed by its `ses_…` id — there is no transcript file, so
/// this adapter's "sourcePath" is the session id.
public struct OpenCodeAdapter: Sendable {
    public init() {}

    public static func databaseURL(opencodeHome: URL) -> URL {
        opencodeHome.appendingPathComponent("opencode.db")
    }

    /// The model OpenCode is most likely to run a resumed session with: its
    /// most recently used one. OpenCode ignores the models stamped on imported
    /// messages and continues with the user's own configuration, so transfer
    /// budgets must target this, not the mapped model.
    public func mostRecentModel(opencodeHome: URL) -> String? {
        let database = Self.databaseURL(opencodeHome: opencodeHome)
        guard FileManager.default.fileExists(atPath: database.path) else {
            return nil
        }
        let rows = (try? OpenCodeSQL.query(
            database: database,
            sql: "SELECT model FROM session WHERE model IS NOT NULL AND id NOT LIKE 'ses_agsync%' ORDER BY time_updated DESC LIMIT 1;"
        )) ?? []
        return Self.modelReference(fromColumn: rows.first?.string("model"))
    }

    public func importSession(sessionID: String, opencodeHome: URL) throws -> CanonicalSession? {
        let database = Self.databaseURL(opencodeHome: opencodeHome)
        guard FileManager.default.fileExists(atPath: database.path) else {
            return nil
        }

        let sessionRows = try OpenCodeSQL.query(
            database: database,
            sql: "SELECT id, directory, title, model, time_created, time_updated FROM session WHERE id = \(OpenCodeSQL.quote(sessionID));"
        )
        guard let sessionRow = sessionRows.first else {
            return nil
        }

        let messageRows = try OpenCodeSQL.query(
            database: database,
            sql: "SELECT id, data, time_created FROM message WHERE session_id = \(OpenCodeSQL.quote(sessionID)) ORDER BY time_created, id;"
        )
        let partRows = try OpenCodeSQL.query(
            database: database,
            sql: "SELECT id, message_id, data, time_created FROM part WHERE session_id = \(OpenCodeSQL.quote(sessionID)) ORDER BY time_created, id;"
        )

        var partsByMessage: [String: [[String: JSONValue]]] = [:]
        for row in partRows {
            guard let messageID = row.string("message_id"),
                  let data = row.string("data"),
                  let part = Self.jsonObject(data) else {
                continue
            }
            partsByMessage[messageID, default: []].append(part)
        }

        var events: [CanonicalEvent] = []
        var title = sessionRow.string("title") ?? ""
        var sessionModel: String?

        for messageRow in messageRows {
            guard let messageID = messageRow.string("id"),
                  let data = messageRow.string("data"),
                  let message = Self.jsonObject(data) else {
                continue
            }
            let roleString = message.string("role") ?? "user"
            let role: CanonicalRole = roleString == "assistant" ? .assistant : .user
            let timestamp = Date(timeIntervalSince1970: (Self.milliseconds(messageRow["time_created"]) ?? 0) / 1000)
            let messageModel = Self.modelReference(from: message)
            if role == .assistant, sessionModel == nil {
                sessionModel = messageModel
            }

            var textPartIndex = 0
            for part in partsByMessage[messageID] ?? [] {
                switch part.string("type") {
                case "text":
                    guard let text = part.string("text"), !text.isEmpty,
                          role == .assistant || !isProviderLocalNoise(text) else {
                        continue
                    }
                    var metadata: [String: JSONValue] = [:]
                    if role == .assistant, let messageModel {
                        metadata["model"] = .string(messageModel)
                    }
                    events.append(CanonicalEvent(
                        id: "opencode:\(sessionID):\(messageID):\(textPartIndex)",
                        sourceProvider: .opencode,
                        sourceEventID: "\(messageID):\(textPartIndex)",
                        timestamp: timestamp,
                        role: role,
                        kind: "message",
                        text: boundedTranscriptText(text, limit: 60_000),
                        metadata: metadata
                    ))
                    textPartIndex += 1
                case "reasoning":
                    guard let text = part.string("text"), !text.isEmpty else {
                        continue
                    }
                    events.append(CanonicalEvent(
                        id: "opencode:\(sessionID):\(messageID):reasoning:\(textPartIndex)",
                        sourceProvider: .opencode,
                        sourceEventID: "\(messageID):reasoning:\(textPartIndex)",
                        timestamp: timestamp,
                        role: .summary,
                        kind: "reasoning_summary",
                        text: boundedTranscriptText(text, limit: 20_000)
                    ))
                    textPartIndex += 1
                case "tool":
                    guard let callID = part.string("callID") else {
                        continue
                    }
                    let toolName = part.string("tool") ?? "tool"
                    let state = part.object("state") ?? [:]
                    let input = boundedTranscriptText(
                        state.string("input") ?? state["input"]?.prettyString() ?? "",
                        limit: 12_000
                    )
                    var metadata: [String: JSONValue] = [
                        "tool_name": .string(toolName),
                        "tool_id": .string(callID)
                    ]
                    if let operation = ToolTaxonomy.universalOperation(provider: .opencode, toolName: toolName) {
                        metadata["tool_op"] = .string(operation)
                    }
                    events.append(CanonicalEvent(
                        id: "opencode:\(sessionID):\(callID)",
                        sourceProvider: .opencode,
                        sourceEventID: callID,
                        timestamp: timestamp,
                        role: .tool,
                        kind: "tool_use",
                        text: "OpenCode tool call: \(toolName)\n\(input)",
                        metadata: metadata
                    ))
                    let output = boundedTranscriptText(
                        state.string("output") ?? state["output"]?.prettyString() ?? "",
                        limit: 20_000
                    )
                    if !output.isEmpty {
                        events.append(CanonicalEvent(
                            id: "opencode:\(sessionID):\(callID):output",
                            sourceProvider: .opencode,
                            sourceEventID: "\(callID):output",
                            timestamp: timestamp,
                            role: .tool,
                            kind: "tool_result",
                            text: "OpenCode tool output:\n\(output)",
                            metadata: ["tool_id": .string(callID)]
                        ))
                    }
                default:
                    // step-start/step-finish/patch/subtask carry no transcript.
                    continue
                }
            }
        }

        guard !events.isEmpty else {
            return nil
        }

        if title.isEmpty {
            title = cleanTitle(events.first(where: { $0.role == .user && !looksLikeInjectedContext($0.text) })?.text)
                ?? "OpenCode session \(sessionID)"
        }

        let createdAt = Date(timeIntervalSince1970: (Self.milliseconds(sessionRow["time_created"]) ?? 0) / 1000)
        let updatedAt = Date(timeIntervalSince1970: (Self.milliseconds(sessionRow["time_updated"]) ?? 0) / 1000)

        return CanonicalSession(
            id: UUID().uuidString.lowercased(),
            sourceProvider: .opencode,
            sourceSessionID: sessionID,
            sourcePath: sessionID,
            title: String(title.prefix(90)),
            cwd: sessionRow.string("directory") ?? "",
            createdAt: createdAt,
            updatedAt: updatedAt,
            model: Self.modelReference(fromColumn: sessionRow.string("model")) ?? sessionModel,
            contributingProviders: [.opencode],
            events: events
        )
    }

    /// "providerID/modelID" from a message data object.
    static func modelReference(from message: [String: JSONValue]) -> String? {
        if let model = message.object("model"),
           let provider = model.string("providerID"),
           let id = model.string("modelID") ?? model.string("id") {
            return "\(provider)/\(id)"
        }
        if let provider = message.string("providerID"), let id = message.string("modelID") {
            return "\(provider)/\(id)"
        }
        return nil
    }

    static func modelReference(fromColumn column: String?) -> String? {
        guard let column, let object = jsonObject(column) else {
            return nil
        }
        return modelReference(from: ["model": .object(object)])
    }

    static func jsonObject(_ text: String) -> [String: JSONValue]? {
        guard let foundation = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let value = try? JSONValue.foundation(foundation),
              case .object(let object) = value else {
            return nil
        }
        return object
    }

    static func milliseconds(_ value: JSONValue?) -> Double? {
        if case .number(let number) = value {
            return number
        }
        if let text = value?.stringValue {
            return Double(text)
        }
        return nil
    }
}

enum OpenCodeSQL {
    static func quote(_ value: String) -> String {
        SQL.quote(value)
    }

    static func query(database: URL, sql: String) throws -> [[String: JSONValue]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-json", "-readonly", database.path, sql]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // Drain before waiting — large results deadlock a full pipe otherwise.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? "sqlite3 failed"
            throw AgentSyncError.commandFailed("opencode.db query failed: \(message)")
        }
        guard !data.isEmpty else {
            return []
        }
        guard let foundation = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return []
        }
        return foundation.compactMap { row in
            guard let value = try? JSONValue.foundation(row), case .object(let object) = value else {
                return nil
            }
            return object
        }
    }
}
