import AgentSyncCore
import Foundation

@main
struct AgentSyncCLI {
    static func main() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        let command = args.isEmpty ? "help" : args.removeFirst()

        switch command {
        case "sync-once":
            let config = try parseConfiguration(args)
            let report = try SyncEngine(configuration: config).syncOnce()
            print("imported=\(report.importedSessions) continuations=\(report.importedContinuations) rendered=\(report.renderedMirrors) skipped_bridge_owned=\(report.skippedBridgeOwnedSources)")
            for warning in report.warnings {
                print("warning: \(warning)")
            }
        case "scan":
            let config = try parseConfiguration(args)
            let engine = SyncEngine(configuration: config)
            _ = try engine.syncOnce()
            let state = try engine.currentState()
            print("canonical_sessions=\(state.canonicalSessions.count)")
            print("mirrors=\(state.mirrorsByNativeSession.count)")
            for session in state.canonicalSessions.values.sorted(by: { $0.createdAt < $1.createdAt }) {
                print("\(session.sourceProvider.rawValue):\(session.sourceSessionID) -> \(session.title)")
            }
        case "prepare-resume":
            let config = try parseConfiguration(args)
            ModelCatalog.configure(stateDirectory: config.stateDirectory)
            guard let providerRaw = value(after: "--provider", in: args),
                  let provider = AgentKind(rawValue: providerRaw),
                  let path = value(after: "--path", in: args) else {
                throw AgentSyncError.invalidArguments("prepare-resume requires --provider claude|codex and --path FILE plus the home/state flags")
            }
            let mode = value(after: "--mode", in: args).flatMap(ResumeMode.init(rawValue:)) ?? .auto
            let target = value(after: "--target", in: args).flatMap(AgentKind.init(rawValue:))
            let ticket = try SyncEngine(configuration: config).prepareResume(
                provider: provider,
                sourcePath: provider == .opencode ? path : NSString(string: path).expandingTildeInPath,
                target: target,
                mode: mode
            )
            print("target=\(ticket.targetProvider.rawValue) session=\(ticket.targetSessionID) cwd=\(ticket.workingDirectory) handoff=\(ticket.usedHandoff)")
        case "update-model-catalog":
            guard let output = value(after: "--output", in: args) else {
                throw AgentSyncError.invalidArguments("update-model-catalog requires --output PATH")
            }
            guard let map = ModelCatalog.fetchDistilled() else {
                throw AgentSyncError.commandFailed("Could not fetch models.dev catalog.")
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(map).write(to: URL(fileURLWithPath: NSString(string: output).expandingTildeInPath), options: [.atomic])
            print("wrote \(map.count) model contexts to \(output)")
        case "migrate-state":
            guard let stateDir = value(after: "--state-dir", in: args) else {
                throw AgentSyncError.invalidArguments("migrate-state requires --state-dir")
            }
            let directory = URL(fileURLWithPath: NSString(string: stateDir).expandingTildeInPath, isDirectory: true)
            let start = Date()
            let state = try BridgeStateStore(stateDirectory: directory).load()
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(start))
            print("state schema=\(state.schemaVersion) canonical_sessions=\(state.canonicalSessions.count) mirrors=\(state.mirrorsByNativeSession.count) elapsed=\(elapsed)s")
        case "prune-state":
            guard let stateDir = value(after: "--state-dir", in: args) else {
                throw AgentSyncError.invalidArguments("prune-state requires --state-dir")
            }
            let directory = URL(fileURLWithPath: NSString(string: stateDir).expandingTildeInPath, isDirectory: true)
            let store = BridgeStateStore(stateDirectory: directory)
            var state = try store.load()

            for canonicalID in state.canonicalSessions.keys {
                let events = try store.loadEvents(canonicalSessionID: canonicalID)
                let deduped = dedupeEventsByContent(events)
                if deduped.count != events.count {
                    try store.saveEvents(deduped, canonicalSessionID: canonicalID)
                    print("compacted \(canonicalID): \(events.count) -> \(deduped.count) events")
                }

                let survivingIDs = Set(deduped.map(\.id))
                let mirrors = state.mirrorsByNativeSession.filter { $0.value.canonicalSessionID == canonicalID }
                for (key, record) in mirrors {
                    // A mirror whose file holds far more events than the deduped
                    // conversation is a runaway artifact of the old echo loop.
                    // Its unique content is already in the canonical store, so
                    // drop the bridge-owned file; the next resume renders fresh.
                    if record.renderedNativeEventIDs.count > deduped.count + 16 {
                        // Only transcript files are removable artifacts;
                        // database-backed mirrors (opencode://…) are not files.
                        if record.targetPath.hasSuffix(".jsonl") {
                            try? FileManager.default.removeItem(atPath: record.targetPath)
                        }
                        state.mirrorsByNativeSession.removeValue(forKey: key)
                        print("removed runaway mirror \(record.targetProvider.rawValue):\(record.targetSessionID) (\(record.renderedNativeEventIDs.count) rendered events)")
                        continue
                    }
                    var record = record
                    let trimmed = record.importedNativeEventIDs.filter(survivingIDs.contains)
                    if trimmed.count != record.importedNativeEventIDs.count {
                        record.importedNativeEventIDs = trimmed
                        state.mirrorsByNativeSession[key] = record
                        print("trimmed mirror \(record.targetProvider.rawValue):\(record.targetSessionID) imported ids -> \(trimmed.count)")
                    }
                }
            }

            try store.save(state)
            print("pruned state: canonical_sessions=\(state.canonicalSessions.count) mirrors=\(state.mirrorsByNativeSession.count)")
        case "e2e":
            let root = try parseRoot(args)
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
            let fixture = AgentSyncFixtureBuilder(root: root)
            try fixture.create()
            let engine = SyncEngine(configuration: fixture.configuration())
            let first = try engine.syncOnce()
            let second = try engine.syncOnce()
            let state = try engine.currentState()
            print("root=\(root.path)")
            print("first_sync imported=\(first.importedSessions) continuations=\(first.importedContinuations) rendered=\(first.renderedMirrors) skipped_bridge_owned=\(first.skippedBridgeOwnedSources)")
            print("second_sync imported=\(second.importedSessions) continuations=\(second.importedContinuations) rendered=\(second.renderedMirrors) skipped_bridge_owned=\(second.skippedBridgeOwnedSources)")
            print("canonical_sessions=\(state.canonicalSessions.count)")
            print("mirrors=\(state.mirrorsByNativeSession.count)")
            for mirror in state.mirrorsByNativeSession.values.sorted(by: { $0.targetPath < $1.targetPath }) {
                print("mirror \(mirror.targetProvider.rawValue):\(mirror.targetSessionID) \(mirror.targetPath)")
            }
        default:
            printUsage()
        }
    }

    private static func parseRoot(_ args: [String]) throws -> URL {
        if let value = value(after: "--root", in: args) {
            return URL(fileURLWithPath: NSString(string: value).expandingTildeInPath, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-sync-e2e-\(UUID().uuidString.lowercased())", isDirectory: true)
    }

    private static func parseConfiguration(_ args: [String]) throws -> AgentSyncConfiguration {
        guard let claudeHome = value(after: "--claude-home", in: args),
              let codexHome = value(after: "--codex-home", in: args),
              let stateDir = value(after: "--state-dir", in: args) else {
            throw AgentSyncError.invalidArguments("sync-once and scan require --claude-home, --codex-home, and --state-dir")
        }

        return AgentSyncConfiguration(
            claudeHome: URL(fileURLWithPath: NSString(string: claudeHome).expandingTildeInPath, isDirectory: true),
            codexHome: URL(fileURLWithPath: NSString(string: codexHome).expandingTildeInPath, isDirectory: true),
            stateDirectory: URL(fileURLWithPath: NSString(string: stateDir).expandingTildeInPath, isDirectory: true),
            defaultCodexModel: value(after: "--codex-model", in: args) ?? "gpt-5.5",
            defaultClaudeModel: value(after: "--claude-model", in: args) ?? "claude-sonnet-5",
            sessionLookbackDays: intValue(after: "--lookback-days", in: args) ?? 14,
            maximumImportedSessions: intValue(after: "--max-sessions", in: args) ?? 3
        )
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else {
            return nil
        }
        return args[index + 1]
    }

    private static func intValue(after flag: String, in args: [String]) -> Int? {
        value(after: flag, in: args).flatMap(Int.init)
    }

    private static func printUsage() {
        print(
            """
            continuo-cli — headless access to the Continuo conversion engine

            Commands (HOMES = --claude-home PATH --codex-home PATH --state-dir PATH):
              scan HOMES [--lookback-days N] [--max-sessions N]
              sync-once HOMES [--codex-model NAME] [--claude-model NAME] [--lookback-days N] [--max-sessions N]
              prepare-resume HOMES --provider claude|codex|opencode --path FILE|SESSION_ID [--target AGENT] [--mode auto|full|handoff]
              update-model-catalog --output PATH
              migrate-state --state-dir PATH
              prune-state --state-dir PATH
              e2e [--root PATH]
            """
        )
    }
}
