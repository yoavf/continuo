import Foundation
import Darwin

public struct BridgeState: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var canonicalByNativeSession: [String: String]
    public var canonicalSessions: [String: CanonicalSessionSummary]
    public var mirrorsByNativeSession: [String: MirrorRecord]

    public init(
        schemaVersion: Int = 2,
        canonicalByNativeSession: [String: String] = [:],
        canonicalSessions: [String: CanonicalSessionSummary] = [:],
        mirrorsByNativeSession: [String: MirrorRecord] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.canonicalByNativeSession = canonicalByNativeSession
        self.canonicalSessions = canonicalSessions
        self.mirrorsByNativeSession = mirrorsByNativeSession
    }

    public static let empty = BridgeState()

    public static func nativeKey(provider: AgentKind, sessionID: String) -> String {
        "\(provider.rawValue):\(sessionID)"
    }

    /// The most recently updated mirror of a canonical session for a target
    /// provider. Multiple mirrors can exist once a continued (frozen) mirror
    /// has been superseded by a fresh render; on an updatedAt tie the fresh
    /// (uncontinued) mirror is the successor.
    public func latestMirror(canonicalSessionID: String, targetProvider: AgentKind) -> MirrorRecord? {
        mirrorsByNativeSession.values
            .filter {
                $0.canonicalSessionID == canonicalSessionID
                    && $0.targetProvider == targetProvider
                    && !$0.isPendingWrite
            }
            .max { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt < rhs.updatedAt
                }
                if lhs.importedNativeEventIDs.isEmpty != rhs.importedNativeEventIDs.isEmpty {
                    return !lhs.importedNativeEventIDs.isEmpty
                }
                return lhs.targetSessionID < rhs.targetSessionID
            }
    }
}

/// Bridge state on disk is deliberately small: `bridge-state.json` carries the
/// native↔canonical maps, session summaries, and mirror ownership records.
/// Each canonical session's events live in `sessions/<id>.json`, loaded only
/// when that conversation is converted — never for listing or annotation.
public final class BridgeStateStore {
    private let stateDirectory: URL
    private let stateURL: URL
    private let fm: FileManager

    /// Serializes loads so two threads can't both run the (expensive, one-time)
    /// legacy migration.
    private static let migrationLock = NSLock()
    /// Serializes mutations within this process. The file lock below extends
    /// the same guarantee to the menu-bar app and CLI running concurrently.
    private static let processMutationLock = NSLock()

    public init(stateDirectory: URL, fileManager: FileManager = .default) {
        self.stateDirectory = stateDirectory
        self.stateURL = stateDirectory.appendingPathComponent("bridge-state.json")
        self.fm = fileManager
    }

    /// Runs one complete bridge mutation without another app/CLI process
    /// loading the same state and later overwriting it with a stale copy.
    func withExclusiveMutation<T>(_ operation: () throws -> T) throws -> T {
        try fm.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        Self.processMutationLock.lock()
        defer { Self.processMutationLock.unlock() }

        let lockURL = stateDirectory.appendingPathComponent(".bridge-state.lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw AgentSyncError.commandFailed("Could not open bridge-state lock at \(lockURL.path).")
        }
        defer { Darwin.close(descriptor) }

        guard flock(descriptor, LOCK_EX) == 0 else {
            throw AgentSyncError.commandFailed("Could not lock bridge state at \(stateDirectory.path).")
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    public func load() throws -> BridgeState {
        try withExclusiveMutation {
            try loadWhileLocked()
        }
    }

    /// Loads, mutates, and saves bridge state under one app/CLI process lock.
    public func withExclusiveStateMutation<T>(
        _ operation: (inout BridgeState) throws -> T
    ) throws -> T {
        try withExclusiveMutation {
            var state = try loadWhileLocked()
            let result = try operation(&state)
            try save(state)
            return result
        }
    }

    /// Caller must already hold `withExclusiveMutation`.
    func loadWhileLocked() throws -> BridgeState {
        Self.migrationLock.lock()
        defer { Self.migrationLock.unlock() }

        let readableStateURL: URL
        if fm.fileExists(atPath: stateURL.path) {
            readableStateURL = stateURL
        } else if fm.fileExists(atPath: backupURL.path) {
            readableStateURL = backupURL
        } else {
            return .empty
        }
        let data = try Data(contentsOf: readableStateURL)
        let stored = try Self.decoder().decode(StoredState.self, from: data)
        let state = BridgeState(
            schemaVersion: 2,
            canonicalByNativeSession: stored.canonicalByNativeSession,
            canonicalSessions: stored.canonicalSessions.mapValues(\.summary),
            mirrorsByNativeSession: stored.mirrorsByNativeSession
        )

        if stored.schemaVersion < 2 {
            // One-time migration from the v1 monolith: split embedded events
            // into per-session files, shrink the state file, and drop the old
            // full-size backup.
            for (canonicalID, canonical) in stored.canonicalSessions {
                try saveEvents(canonical.events ?? [], canonicalSessionID: canonicalID)
            }
            try save(state)
            try? fm.removeItem(at: backupURL)
        }
        return state
    }

    public func save(_ state: BridgeState) throws {
        try fm.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let data = try Self.encoder(outputFormatting: [.prettyPrinted, .sortedKeys]).encode(state)
        let tmp = stateDirectory.appendingPathComponent(".bridge-state.json.tmp")
        try data.write(to: tmp, options: [.atomic])
        if fm.fileExists(atPath: stateURL.path) {
            if fm.fileExists(atPath: backupURL.path) {
                try fm.removeItem(at: backupURL)
            }
            try fm.copyItem(at: stateURL, to: backupURL)
        }
        guard Darwin.rename(tmp.path, stateURL.path) == 0 else {
            throw AgentSyncError.commandFailed(
                "Could not atomically replace bridge state at \(stateURL.path) (errno \(errno))."
            )
        }
    }

    public func loadEvents(canonicalSessionID: String) throws -> [CanonicalEvent] {
        let url = eventsURL(canonicalSessionID)
        guard fm.fileExists(atPath: url.path) else {
            return []
        }
        return try Self.decoder().decode([CanonicalEvent].self, from: Data(contentsOf: url))
    }

    public func saveEvents(_ events: [CanonicalEvent], canonicalSessionID: String) throws {
        try fm.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        let data = try Self.encoder(outputFormatting: [.sortedKeys]).encode(events)
        try data.write(to: eventsURL(canonicalSessionID), options: [.atomic])
    }

    private var backupURL: URL {
        stateDirectory.appendingPathComponent("bridge-state.backup.json")
    }

    private var sessionsDirectory: URL {
        stateDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    private func eventsURL(_ canonicalSessionID: String) -> URL {
        sessionsDirectory.appendingPathComponent("\(canonicalSessionID).json")
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        // Accepts both fractional and whole-second timestamps so state files
        // written before sub-second precision still load.
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = DateCoding.parse(string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unrecognized date: \(string)"
                )
            }
            return date
        }
        return decoder
    }

    private static func encoder(outputFormatting: JSONEncoder.OutputFormatting) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = outputFormatting
        // Sub-second precision matters: mirror recency decides which mirror a
        // resume resolves to, and several can be written within one second.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(DateCoding.render(date))
        }
        return encoder
    }
}

/// Superset of v1 and v2 layouts: v1 embedded full events in each canonical
/// session; v2 stores summaries only.
private struct StoredState: Decodable {
    var schemaVersion: Int
    var canonicalByNativeSession: [String: String]
    var canonicalSessions: [String: StoredCanonicalSession]
    var mirrorsByNativeSession: [String: MirrorRecord]
}

private struct StoredCanonicalSession: Decodable {
    var id: String
    var sourceProvider: AgentKind
    var sourceSessionID: String
    var sourcePath: String
    var title: String
    var cwd: String
    var createdAt: Date
    var updatedAt: Date
    var model: String?
    var contributingProviders: [AgentKind]
    var events: [CanonicalEvent]?

    var summary: CanonicalSessionSummary {
        CanonicalSessionSummary(session: CanonicalSession(
            id: id,
            sourceProvider: sourceProvider,
            sourceSessionID: sourceSessionID,
            sourcePath: sourcePath,
            title: title,
            cwd: cwd,
            createdAt: createdAt,
            updatedAt: updatedAt,
            model: model,
            contributingProviders: contributingProviders,
            events: []
        ))
    }
}
