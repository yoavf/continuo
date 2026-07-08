import Foundation

struct CodexThreadIndex {
    let codexHome: URL

    var databaseURL: URL {
        codexHome.appendingPathComponent("state_5.sqlite")
    }

    /// Best-effort: registers the mirror in Codex's thread index so it shows up
    /// in `codex resume` pickers. The schema is Codex-owned and unversioned, so
    /// the insert is built from the columns that actually exist; if the table is
    /// missing, incompatible, or the insert fails, we skip indexing rather than
    /// fail the render — `codex resume <id>` works from the rollout file alone.
    func upsertThread(
        session: CanonicalSession,
        targetSessionID: String,
        rolloutPath: String,
        model: String,
        source: String
    ) -> Bool {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return false
        }
        guard let existingColumns = try? tableColumns(), !existingColumns.isEmpty else {
            return false
        }

        let created = Int(session.createdAt.timeIntervalSince1970)
        let updated = Int(session.updatedAt.timeIntervalSince1970)
        let createdMS = Int(session.createdAt.timeIntervalSince1970 * 1000)
        let updatedMS = Int(session.updatedAt.timeIntervalSince1970 * 1000)
        let preview = SQL.quote(session.events.first(where: { $0.role == .user })?.text ?? session.title)

        let candidateValues: [(column: String, sql: String)] = [
            ("id", SQL.quote(targetSessionID)),
            ("rollout_path", SQL.quote(rolloutPath)),
            ("created_at", String(created)),
            ("updated_at", String(updated)),
            ("source", SQL.quote(source)),
            ("model_provider", SQL.quote("openai")),
            ("cwd", SQL.quote(session.cwd)),
            ("title", SQL.quote("[Bridge] \(session.title)")),
            ("sandbox_policy", SQL.quote("{\"type\":\"workspace-write\"}")),
            ("approval_mode", SQL.quote("untrusted")),
            ("tokens_used", "0"),
            ("has_user_event", "1"),
            ("archived", "0"),
            ("cli_version", SQL.quote("agent-sync-1")),
            ("first_user_message", preview),
            ("memory_mode", SQL.quote("enabled")),
            ("model", SQL.quote(model)),
            ("reasoning_effort", SQL.quote("high")),
            ("created_at_ms", String(createdMS)),
            ("updated_at_ms", String(updatedMS)),
            ("thread_source", SQL.quote("user")),
            ("preview", preview),
            ("recency_at", String(updated)),
            ("recency_at_ms", String(updatedMS))
        ]

        let requiredColumns = ["id", "rollout_path", "created_at", "updated_at", "cwd", "title"]
        guard requiredColumns.allSatisfy(existingColumns.contains) else {
            return false
        }

        let insertValues = candidateValues.filter { existingColumns.contains($0.column) }
        let updatableColumns = [
            "rollout_path", "updated_at", "cwd", "title", "first_user_message",
            "source", "model", "thread_source", "updated_at_ms", "preview",
            "recency_at", "recency_at_ms"
        ].filter(existingColumns.contains)

        let sql = """
        INSERT INTO threads (\(insertValues.map(\.column).joined(separator: ", ")))
        VALUES (\(insertValues.map(\.sql).joined(separator: ", ")))
        ON CONFLICT(id) DO UPDATE SET
        \(updatableColumns.map { "\($0) = excluded.\($0)" }.joined(separator: ",\n"));
        """

        do {
            _ = try runSQLiteCapturing(sql)
            return true
        } catch {
            return false
        }
    }

    private func tableColumns() throws -> [String] {
        let output = try runSQLiteCapturing("PRAGMA table_info(threads);")
        return output
            .split(separator: "\n")
            .compactMap { line -> String? in
                let fields = line.split(separator: "|", omittingEmptySubsequences: false)
                guard fields.count > 1 else {
                    return nil
                }
                return String(fields[1])
            }
    }

    private func runSQLiteCapturing(_ sql: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [databaseURL.path, sql]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "sqlite3 failed"
            throw AgentSyncError.commandFailed(message)
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

enum SQL {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
