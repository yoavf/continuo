import Foundation

/// A cheap, read-only summary of one native session, built from the first and
/// last few kilobytes of its transcript. This is what the picker UI lists.
public struct SessionPreview: Identifiable, Equatable, Sendable {
    public var provider: AgentKind
    public var sessionID: String
    public var path: String
    public var title: String
    /// First real user message (injected context skipped), for on-device AI
    /// title generation. Longer than the display title.
    public var snippet: String
    /// Models observed near the head of the transcript, in order of appearance.
    public var models: [String]
    /// Rough conversation size in tokens, estimated from stored bytes.
    public var estimatedTokens: Int
    public var cwd: String
    public var updatedAt: Date

    public var tokensLabel: String {
        switch estimatedTokens {
        case ..<1_000:
            return "<1k tokens"
        case ..<1_000_000:
            return "\(estimatedTokens / 1_000)k tokens"
        default:
            return String(format: "%.1fM tokens", Double(estimatedTokens) / 1_000_000)
        }
    }

    public var id: String {
        BridgeState.nativeKey(provider: provider, sessionID: sessionID)
    }

    public var projectName: String {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Unknown project"
        }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        if let repoName = Self.repositoryName(forPath: expanded) {
            return repoName
        }
        let name = URL(fileURLWithPath: expanded).lastPathComponent
        guard !name.isEmpty, name != "/" else {
            return expanded
        }
        return name
    }

    /// Resolves a session cwd to its project name the way git would: walk up
    /// to the nearest `.git`. A worktree's `.git` is a file pointing at the
    /// main repo ("gitdir: /path/to/repo/.git/worktrees/x") — use the repo's
    /// name so worktree sessions (including slash-branches like "ship/happens")
    /// group under their project. A `.git` directory names the repo root.
    static func repositoryName(forPath path: String) -> String? {
        var current = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let fm = FileManager.default
        for _ in 0..<8 {
            let gitURL = current.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: gitURL.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    return current.lastPathComponent
                }
                if let contents = try? String(contentsOfFile: gitURL.path, encoding: .utf8),
                   let range = contents.range(of: #"gitdir:\s*(.+)/\.git/worktrees/"#, options: .regularExpression) {
                    let match = String(contents[range])
                    if let colon = match.range(of: ":") {
                        let repoPath = match[colon.upperBound...]
                            .trimmingCharacters(in: .whitespaces)
                            .replacingOccurrences(of: "/.git/worktrees/", with: "")
                        let name = URL(fileURLWithPath: repoPath).lastPathComponent
                        return name.isEmpty ? nil : name
                    }
                }
                return current.lastPathComponent
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path || parent.path == "/" {
                return nil
            }
            current = parent
        }
        return nil
    }
}

public enum RecentSessionScanner {
    /// Newest-first previews across all providers.
    public static func scan(
        claudeHome: URL,
        codexHome: URL,
        opencodeHome: URL,
        lookbackDays: Int?,
        maximumPerProvider: Int
    ) throws -> [SessionPreview] {
        let claude = try scan(
            provider: .claude,
            root: claudeHome.appendingPathComponent("projects", isDirectory: true),
            lookbackDays: lookbackDays,
            maximum: maximumPerProvider,
            excludingPathComponents: ["subagents"]
        )
        let codex = try scan(
            provider: .codex,
            root: codexHome.appendingPathComponent("sessions", isDirectory: true),
            codexTitles: codexThreadTitles(codexHome: codexHome),
            lookbackDays: lookbackDays,
            maximum: maximumPerProvider
        )
        let opencode = opencodePreviews(
            opencodeHome: opencodeHome,
            lookbackDays: lookbackDays,
            maximum: maximumPerProvider
        )
        return (claude + codex + opencode).sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.id < rhs.id
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    /// OpenCode sessions come from its database; child sessions (parent_id)
    /// are subagent tasks, not resumable conversations.
    private static func opencodePreviews(
        opencodeHome: URL,
        lookbackDays: Int?,
        maximum: Int
    ) -> [SessionPreview] {
        let database = OpenCodeAdapter.databaseURL(opencodeHome: opencodeHome)
        guard FileManager.default.fileExists(atPath: database.path) else {
            return []
        }
        var sql = "SELECT id, title, directory, model, time_updated, tokens_input + tokens_cache_read AS context_tokens, (SELECT SUM(LENGTH(data)) FROM part WHERE part.session_id = session.id) AS part_bytes FROM session WHERE parent_id IS NULL AND time_archived IS NULL"
        if let lookbackDays {
            let cutoff = Int(Date().addingTimeInterval(-Double(lookbackDays) * 24 * 60 * 60).timeIntervalSince1970 * 1000)
            sql += " AND time_updated >= \(cutoff)"
        }
        sql += " ORDER BY time_updated DESC LIMIT \(maximum);"
        let rows = (try? OpenCodeSQL.query(database: database, sql: sql)) ?? []
        return rows.compactMap { row in
            guard let id = row.string("id") else {
                return nil
            }
            let updatedMS = OpenCodeAdapter.milliseconds(row["time_updated"]) ?? 0
            let model = OpenCodeAdapter.modelReference(fromColumn: row.string("model"))
            return SessionPreview(
                provider: .opencode,
                sessionID: id,
                path: id,
                title: cleanTitle(row.string("title")) ?? "OpenCode session \(id)",
                snippet: "",
                models: model.map { [$0] } ?? [],
                estimatedTokens: {
                    let recorded = Int(OpenCodeAdapter.milliseconds(row["context_tokens"]) ?? 0)
                    return recorded > 0 ? recorded : Int(OpenCodeAdapter.milliseconds(row["part_bytes"]) ?? 0) / 4
                }(),
                cwd: row.string("directory") ?? "",
                updatedAt: Date(timeIntervalSince1970: updatedMS / 1000)
            )
        }
    }

    private static func scan(
        provider: AgentKind,
        root: URL,
        codexTitles: [String: String] = [:],
        lookbackDays: Int?,
        maximum: Int,
        excludingPathComponents: Set<String> = []
    ) throws -> [SessionPreview] {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return []
        }
        let files = try discoverJSONLSessionFiles(
            under: root,
            lookbackDays: lookbackDays,
            maximumSessions: maximum,
            excludingPathComponents: excludingPathComponents
        )
        return files.map { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modifiedAt = values?.contentModificationDate ?? Date.distantPast
            // JSONL carries roughly 2x envelope overhead over the raw text, on
            // top of ~3.4 chars/token.
            let estimatedTokens = (values?.fileSize ?? 0) / 7
            let prefixObjects = (try? readEdgeObjects(from: url, fromEnd: false)) ?? []
            let tailObjects = (try? readEdgeObjects(from: url, fromEnd: true)) ?? []
            switch provider {
            case .codex:
                return codexPreview(url: url, modifiedAt: modifiedAt, estimatedTokens: codexContextTokens(in: tailObjects) ?? estimatedTokens, prefixObjects: prefixObjects, threadTitles: codexTitles)
            default:
                // .claude — opencode never reaches the JSONL scan path.
                return claudePreview(url: url, modifiedAt: modifiedAt, estimatedTokens: claudeContextTokens(in: tailObjects) ?? estimatedTokens, prefixObjects: prefixObjects, tailObjects: tailObjects)
            }
        }
    }

    /// Real context size from the transcript's own records — raw file size
    /// wildly overstates codex sessions (encrypted reasoning, telemetry).
    /// Codex: the last token_count event's last_token_usage.
    private static func codexContextTokens(in tailObjects: [[String: JSONValue]]) -> Int? {
        for object in tailObjects.reversed() {
            guard object.string("type") == "event_msg",
                  let payload = object.object("payload"),
                  payload.string("type") == "token_count",
                  let info = payload.object("info"),
                  let usage = info.object("last_token_usage"),
                  case .number(let total)? = usage["total_tokens"] else {
                continue
            }
            return Int(total)
        }
        return nil
    }

    /// Claude: the last assistant usage record; context ≈ input + cache reads
    /// + cache writes.
    private static func claudeContextTokens(in tailObjects: [[String: JSONValue]]) -> Int? {
        for object in tailObjects.reversed() {
            guard object.string("type") == "assistant",
                  let usage = object.object("message")?.object("usage") else {
                continue
            }
            func number(_ key: String) -> Double {
                if case .number(let value)? = usage[key] {
                    return value
                }
                return 0
            }
            let total = number("input_tokens") + number("cache_read_input_tokens") + number("cache_creation_input_tokens")
            if total > 0 {
                return Int(total)
            }
        }
        return nil
    }

    /// Codex keeps the real thread titles in its state database; the rollout
    /// files only carry the raw prompt stream.
    private static func codexThreadTitles(codexHome: URL) -> [String: String] {
        let databaseURL = codexHome.appendingPathComponent("state_5.sqlite")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return [:]
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-json",
            databaseURL.path,
            "SELECT id, substr(title, 1, 200) AS title FROM threads ORDER BY updated_at DESC LIMIT 300;"
        ]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        guard (try? process.run()) != nil else {
            return [:]
        }
        // Drain stdout BEFORE waiting: past ~64KB of output the child blocks on
        // a full pipe while we block in waitUntilExit — a deadlock.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return [:]
        }
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return [:]
        }
        var titles: [String: String] = [:]
        for row in rows {
            if let id = row["id"] as? String, let title = row["title"] as? String, !title.isEmpty {
                titles[id] = title
            }
        }
        return titles
    }

    private static func claudePreview(
        url: URL,
        modifiedAt: Date,
        estimatedTokens: Int,
        prefixObjects: [[String: JSONValue]],
        tailObjects: [[String: JSONValue]]
    ) -> SessionPreview {
        let fallbackID = url.deletingPathExtension().lastPathComponent
        var sessionID = fallbackID
        var cwd = PathEncoding.decodeClaudeProjectName(url.deletingLastPathComponent().lastPathComponent)
        var title: String?
        var snippet: String?
        var models: [String] = []

        for object in prefixObjects {
            sessionID = object.string("sessionId") ?? sessionID
            cwd = object.string("cwd") ?? cwd
            if let message = object.object("message") {
                if let model = message.string("model"), !models.contains(model) {
                    models.append(model)
                }
                if snippet == nil,
                   object.string("type") == "user",
                   let text = previewText(from: message["content"]),
                   !looksLikeInjectedContext(text) {
                    snippet = text
                }
            }
        }
        // ai-title lines recur through the file as Claude re-titles; the last
        // one in the tail is current.
        for object in (prefixObjects + tailObjects) {
            if let aiTitle = object.string("aiTitle") {
                title = aiTitle
            }
        }

        return SessionPreview(
            provider: .claude,
            sessionID: sessionID,
            path: url.path,
            title: cleanTitle(title) ?? cleanTitle(snippet) ?? "Claude session \(sessionID)",
            snippet: String((snippet ?? "").prefix(600)),
            models: models,
            estimatedTokens: estimatedTokens,
            cwd: cwd,
            updatedAt: modifiedAt
        )
    }

    private static func codexPreview(
        url: URL,
        modifiedAt: Date,
        estimatedTokens: Int,
        prefixObjects: [[String: JSONValue]],
        threadTitles: [String: String]
    ) -> SessionPreview {
        var sessionID = codexSessionIDFromFilename(url) ?? url.deletingPathExtension().lastPathComponent
        var cwd = ""
        var typedMessage: String?
        var fallbackMessage: String?
        var models: [String] = []

        for object in prefixObjects {
            switch object.string("type") {
            case "session_meta":
                if let payload = object.object("payload") {
                    sessionID = payload.string("session_id") ?? payload.string("id") ?? sessionID
                    cwd = payload.string("cwd") ?? cwd
                }
            case "turn_context":
                if let payload = object.object("payload") {
                    cwd = payload.string("cwd") ?? cwd
                    if let model = payload.string("model"), !models.contains(model) {
                        models.append(model)
                    }
                }
            case "event_msg":
                if typedMessage == nil,
                   let payload = object.object("payload"),
                   payload.string("type") == "user_message",
                   let message = payload.string("message"),
                   !looksLikeInjectedContext(message) {
                    typedMessage = message
                }
            case "response_item":
                if fallbackMessage == nil,
                   let payload = object.object("payload"),
                   payload.string("type") == "message",
                   payload.string("role") == "user",
                   let text = previewText(from: payload["content"]),
                   !looksLikeInjectedContext(text) {
                    fallbackMessage = text
                }
            default:
                break
            }
        }

        let snippet = typedMessage ?? fallbackMessage
        let title = threadTitles[sessionID] ?? snippet
        return SessionPreview(
            provider: .codex,
            sessionID: sessionID,
            path: url.path,
            title: cleanTitle(title) ?? "Codex session \(sessionID)",
            snippet: String((snippet ?? "").prefix(600)),
            models: models,
            estimatedTokens: estimatedTokens,
            cwd: cwd.isEmpty ? url.deletingLastPathComponent().path : cwd,
            updatedAt: modifiedAt
        )
    }

    private static func readEdgeObjects(
        from url: URL,
        fromEnd: Bool,
        maximumBytes: Int = 256 * 1024,
        maximumLines: Int = 160
    ) throws -> [[String: JSONValue]] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data: Data
        if fromEnd {
            let size = (try? handle.seekToEnd()) ?? 0
            let offset = size > UInt64(maximumBytes) ? size - UInt64(maximumBytes) : 0
            try handle.seek(toOffset: offset)
            data = try handle.readToEnd() ?? Data()
        } else {
            data = try handle.read(upToCount: maximumBytes) ?? Data()
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return []
        }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if fromEnd {
            // The first chunk-line may be a partial JSON record; drop it.
            if !lines.isEmpty {
                lines.removeFirst()
            }
            lines = Array(lines.suffix(maximumLines))
        } else {
            lines = Array(lines.prefix(maximumLines))
        }

        var objects: [[String: JSONValue]] = []
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  let foundationValue = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  let value = try? JSONValue.foundation(foundationValue),
                  case .object(let object) = value else {
                continue
            }
            objects.append(object)
        }
        return objects
    }

    private static func previewText(from value: JSONValue?) -> String? {
        guard let value else {
            return nil
        }
        switch value {
        case .string(let text):
            return text
        case .array(let values):
            return values.compactMap { item in
                guard let object = item.objectValue else {
                    return item.stringValue
                }
                return object.string("text") ?? object.string("content")
            }.joined(separator: " ")
        default:
            return nil
        }
    }

}

/// Codex rollout files are named "rollout-<timestamp>-<uuid>.jsonl"; the UUID
/// itself contains dashes, so we match its shape at the end of the name.
func codexSessionIDFromFilename(_ url: URL) -> String? {
    let name = url.deletingPathExtension().lastPathComponent
    guard name.count >= 36 else {
        return nil
    }
    let candidate = String(name.suffix(36))
    let isUUID = candidate.range(
        of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
        options: .regularExpression
    ) != nil
    return isUUID ? candidate : nil
}
