import Foundation

public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case opencode

    /// The agents a session of this provider can be continued in.
    public var resumeTargets: [AgentKind] {
        AgentKind.allCases.filter { $0 != self }
    }
}

public enum CanonicalRole: String, Codable, Sendable {
    case user
    case assistant
    case developer
    case system
    case tool
    case summary
}

public struct CanonicalEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var sourceProvider: AgentKind
    public var sourceEventID: String
    public var timestamp: Date
    public var role: CanonicalRole
    public var kind: String
    public var text: String
    public var metadata: [String: JSONValue]

    public init(
        id: String,
        sourceProvider: AgentKind,
        sourceEventID: String,
        timestamp: Date,
        role: CanonicalRole,
        kind: String,
        text: String,
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.sourceProvider = sourceProvider
        self.sourceEventID = sourceEventID
        self.timestamp = timestamp
        self.role = role
        self.kind = kind
        self.text = text
        self.metadata = metadata
    }
}

public struct CanonicalSession: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var sourceProvider: AgentKind
    public var sourceSessionID: String
    public var sourcePath: String
    public var title: String
    public var cwd: String
    public var createdAt: Date
    public var updatedAt: Date
    public var model: String?
    public var contributingProviders: [AgentKind]
    public var events: [CanonicalEvent]

    public init(
        id: String,
        sourceProvider: AgentKind,
        sourceSessionID: String,
        sourcePath: String,
        title: String,
        cwd: String,
        createdAt: Date,
        updatedAt: Date,
        model: String?,
        contributingProviders: [AgentKind],
        events: [CanonicalEvent]
    ) {
        self.id = id
        self.sourceProvider = sourceProvider
        self.sourceSessionID = sourceSessionID
        self.sourcePath = sourcePath
        self.title = title
        self.cwd = cwd
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.model = model
        self.contributingProviders = contributingProviders
        self.events = events
    }
}

/// Everything about a canonical session except its events. This is what the
/// bridge-state file stores; events live in per-session files and are loaded
/// only when a session is actually converted.
public struct CanonicalSessionSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var sourceProvider: AgentKind
    public var sourceSessionID: String
    public var sourcePath: String
    public var title: String
    public var cwd: String
    public var createdAt: Date
    public var updatedAt: Date
    public var model: String?
    public var contributingProviders: [AgentKind]

    public init(session: CanonicalSession) {
        self.id = session.id
        self.sourceProvider = session.sourceProvider
        self.sourceSessionID = session.sourceSessionID
        self.sourcePath = session.sourcePath
        self.title = session.title
        self.cwd = session.cwd
        self.createdAt = session.createdAt
        self.updatedAt = session.updatedAt
        self.model = session.model
        self.contributingProviders = session.contributingProviders
    }
}

public extension CanonicalSession {
    init(summary: CanonicalSessionSummary, events: [CanonicalEvent]) {
        self.init(
            id: summary.id,
            sourceProvider: summary.sourceProvider,
            sourceSessionID: summary.sourceSessionID,
            sourcePath: summary.sourcePath,
            title: summary.title,
            cwd: summary.cwd,
            createdAt: summary.createdAt,
            updatedAt: summary.updatedAt,
            model: summary.model,
            contributingProviders: summary.contributingProviders,
            events: events
        )
    }
}

public enum MirrorKind: String, Codable, Sendable {
    case full
    case handoff
}

public struct MirrorRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(targetProvider.rawValue):\(targetSessionID)" }
    public var canonicalSessionID: String
    public var targetProvider: AgentKind
    public var targetSessionID: String
    public var targetPath: String
    public var targetIndexPath: String?
    public var rendererVersion: Int
    public var renderedNativeEventIDs: [String]
    public var importedNativeEventIDs: [String]
    /// True only between reserving a brand-new native session and completing
    /// its first write. Retries reuse this reservation instead of minting a
    /// second session.
    public var isPendingWrite: Bool
    /// A full render must never hijack a handoff mirror (or vice versa); each
    /// kind reuses only its own.
    public var kind: MirrorKind
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        canonicalSessionID: String,
        targetProvider: AgentKind,
        targetSessionID: String,
        targetPath: String,
        targetIndexPath: String?,
        rendererVersion: Int,
        renderedNativeEventIDs: [String] = [],
        importedNativeEventIDs: [String] = [],
        isPendingWrite: Bool = false,
        kind: MirrorKind = .full,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.canonicalSessionID = canonicalSessionID
        self.targetProvider = targetProvider
        self.targetSessionID = targetSessionID
        self.targetPath = targetPath
        self.targetIndexPath = targetIndexPath
        self.rendererVersion = rendererVersion
        self.renderedNativeEventIDs = renderedNativeEventIDs
        self.importedNativeEventIDs = importedNativeEventIDs
        self.isPendingWrite = isPendingWrite
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case canonicalSessionID
        case targetProvider
        case targetSessionID
        case targetPath
        case targetIndexPath
        case rendererVersion
        case renderedNativeEventIDs
        case importedNativeEventIDs
        case isPendingWrite
        case kind
        case createdAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.canonicalSessionID = try container.decode(String.self, forKey: .canonicalSessionID)
        self.targetProvider = try container.decode(AgentKind.self, forKey: .targetProvider)
        self.targetSessionID = try container.decode(String.self, forKey: .targetSessionID)
        self.targetPath = try container.decode(String.self, forKey: .targetPath)
        self.targetIndexPath = try container.decodeIfPresent(String.self, forKey: .targetIndexPath)
        self.rendererVersion = try container.decode(Int.self, forKey: .rendererVersion)
        self.renderedNativeEventIDs = try container.decodeIfPresent([String].self, forKey: .renderedNativeEventIDs) ?? []
        self.importedNativeEventIDs = try container.decodeIfPresent([String].self, forKey: .importedNativeEventIDs) ?? []
        self.isPendingWrite = try container.decodeIfPresent(Bool.self, forKey: .isPendingWrite) ?? false
        self.kind = try container.decodeIfPresent(MirrorKind.self, forKey: .kind) ?? .full
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

public struct ResumeTicket: Equatable, Sendable {
    public let targetProvider: AgentKind
    public let targetSessionID: String
    public let workingDirectory: String
    public let usedHandoff: Bool

    public init(targetProvider: AgentKind, targetSessionID: String, workingDirectory: String, usedHandoff: Bool = false) {
        self.targetProvider = targetProvider
        self.targetSessionID = targetSessionID
        self.workingDirectory = workingDirectory
        self.usedHandoff = usedHandoff
    }
}

public struct SyncReport: Codable, Equatable, Sendable {
    public var importedSessions: Int
    public var importedContinuations: Int
    public var renderedMirrors: Int
    public var skippedBridgeOwnedSources: Int
    public var warnings: [String]

    public static let empty = SyncReport(
        importedSessions: 0,
        importedContinuations: 0,
        renderedMirrors: 0,
        skippedBridgeOwnedSources: 0,
        warnings: []
    )
}

public struct ModelMappingRule: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var sourceProvider: AgentKind
    public var targetProvider: AgentKind
    public var sourcePattern: String
    public var targetModel: String

    public init(
        id: String = UUID().uuidString.lowercased(),
        sourceProvider: AgentKind,
        targetProvider: AgentKind,
        sourcePattern: String,
        targetModel: String
    ) {
        self.id = id
        self.sourceProvider = sourceProvider
        self.targetProvider = targetProvider
        self.sourcePattern = sourcePattern
        self.targetModel = targetModel
    }
}

public struct ModelMappingSettings: Codable, Equatable, Sendable {
    public var defaultCodexModel: String
    public var defaultClaudeModel: String
    public var rules: [ModelMappingRule]

    public init(
        defaultCodexModel: String = "gpt-5.5",
        defaultClaudeModel: String = "claude-sonnet-5",
        rules: [ModelMappingRule]? = nil
    ) {
        self.defaultCodexModel = defaultCodexModel
        self.defaultClaudeModel = defaultClaudeModel
        self.rules = rules ?? ModelMappingSettings.defaultRules(
            defaultCodexModel: defaultCodexModel,
            defaultClaudeModel: defaultClaudeModel
        )
    }

    public static func defaultRules(
        defaultCodexModel: String = "gpt-5.5",
        defaultClaudeModel: String = "claude-sonnet-5"
    ) -> [ModelMappingRule] {
        [
            ModelMappingRule(
                sourceProvider: .claude,
                targetProvider: .codex,
                sourcePattern: "claude-opus*",
                targetModel: defaultCodexModel
            ),
            ModelMappingRule(
                sourceProvider: .claude,
                targetProvider: .codex,
                sourcePattern: "claude-sonnet*",
                targetModel: defaultCodexModel
            ),
            ModelMappingRule(
                sourceProvider: .claude,
                targetProvider: .codex,
                sourcePattern: "claude-fable*",
                targetModel: defaultCodexModel
            ),
            ModelMappingRule(
                sourceProvider: .codex,
                targetProvider: .claude,
                sourcePattern: "gpt-5.5*",
                targetModel: defaultClaudeModel
            ),
            ModelMappingRule(
                sourceProvider: .codex,
                targetProvider: .claude,
                sourcePattern: "gpt-5*",
                targetModel: defaultClaudeModel
            )
        ]
    }

    public func targetModel(for session: CanonicalSession, targetProvider: AgentKind) -> String {
        targetModel(forSourceModel: session.model, sourceProvider: session.sourceProvider, targetProvider: targetProvider)
    }

    public func targetModel(
        forSourceModel sourceModel: String?,
        sourceProvider: AgentKind,
        targetProvider: AgentKind
    ) -> String {
        let rawModel = sourceModel ?? ""
        if let rule = rules.first(where: {
            $0.sourceProvider == sourceProvider
                && $0.targetProvider == targetProvider
                && wildcard($0.sourcePattern, matches: rawModel)
        }) {
            return rule.targetModel
        }

        // OpenCode models carry a provider prefix ("anthropic/claude-…",
        // "openai/gpt-…"). Crossing into OpenCode adds the prefix and keeps
        // the model; crossing out strips it and resolves through the family's
        // own rules. Unrelated providers (fireworks, …) fall to defaults.
        let (family, baseModel) = Self.modelFamily(rawModel, provider: sourceProvider)

        switch targetProvider {
        case .opencode:
            switch family {
            case .claude:
                return "anthropic/\(baseModel.isEmpty ? defaultClaudeModel : baseModel)"
            case .codex:
                return "openai/\(baseModel.isEmpty ? defaultCodexModel : baseModel)"
            default:
                return "anthropic/\(defaultClaudeModel)"
            }
        case .claude:
            if family == .claude, !baseModel.isEmpty {
                return baseModel
            }
            if family == .codex, sourceProvider == .opencode {
                return targetModel(forSourceModel: baseModel, sourceProvider: .codex, targetProvider: .claude)
            }
            return defaultClaudeModel
        case .codex:
            if family == .codex, !baseModel.isEmpty {
                return baseModel
            }
            if family == .claude, sourceProvider == .opencode {
                return targetModel(forSourceModel: baseModel, sourceProvider: .claude, targetProvider: .codex)
            }
            return defaultCodexModel
        }
    }

    /// (model family, unprefixed model). Family is nil for providers neither
    /// Anthropic nor OpenAI.
    private static func modelFamily(_ model: String, provider: AgentKind) -> (AgentKind?, String) {
        switch provider {
        case .claude:
            return (.claude, model)
        case .codex:
            return (.codex, model)
        case .opencode:
            if model.hasPrefix("anthropic/") {
                return (.claude, String(model.dropFirst("anthropic/".count)))
            }
            if model.hasPrefix("openai/") {
                return (.codex, String(model.dropFirst("openai/".count)))
            }
            return (nil, model)
        }
    }

    private func wildcard(_ pattern: String, matches value: String) -> Bool {
        let pattern = pattern.lowercased()
        let value = value.lowercased()
        guard pattern.contains("*") else {
            return pattern == value
        }

        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        var remainder = value

        if let first = parts.first, !first.isEmpty {
            guard remainder.hasPrefix(first) else {
                return false
            }
            remainder.removeFirst(first.count)
        }

        for part in parts.dropFirst().dropLast() where !part.isEmpty {
            guard let range = remainder.range(of: part) else {
                return false
            }
            remainder = String(remainder[range.upperBound...])
        }

        if let last = parts.last, !last.isEmpty {
            return remainder.hasSuffix(last)
        }
        return true
    }
}

public struct AgentSyncConfiguration: Equatable, Sendable {
    public var claudeHome: URL
    public var codexHome: URL
    public var opencodeHome: URL
    public var stateDirectory: URL
    public var defaultCodexModel: String
    public var defaultClaudeModel: String
    public var modelMappings: ModelMappingSettings
    /// When set, OpenCode resumes launch with `-m` on this model, and budgets
    /// and stamping follow it. Nil = OpenCode's own choice (most recent).
    public var opencodeResumeModel: String?
    public var sessionLookbackDays: Int?
    public var maximumImportedSessions: Int?

    public init(
        claudeHome: URL,
        codexHome: URL,
        opencodeHome: URL? = nil,
        stateDirectory: URL,
        defaultCodexModel: String = "gpt-5.5",
        defaultClaudeModel: String = "claude-sonnet-5",
        modelMappings: ModelMappingSettings? = nil,
        opencodeResumeModel: String? = nil,
        sessionLookbackDays: Int? = nil,
        maximumImportedSessions: Int? = nil
    ) {
        self.claudeHome = claudeHome
        self.codexHome = codexHome
        self.opencodeHome = opencodeHome ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode", isDirectory: true)
        self.stateDirectory = stateDirectory
        self.defaultCodexModel = defaultCodexModel
        self.defaultClaudeModel = defaultClaudeModel
        self.modelMappings = modelMappings ?? ModelMappingSettings(
            defaultCodexModel: defaultCodexModel,
            defaultClaudeModel: defaultClaudeModel
        )
        self.opencodeResumeModel = opencodeResumeModel
        self.sessionLookbackDays = sessionLookbackDays
        self.maximumImportedSessions = maximumImportedSessions
    }

    public static func productionDefault() -> AgentSyncConfiguration {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return AgentSyncConfiguration(
            claudeHome: home.appendingPathComponent(".claude", isDirectory: true),
            codexHome: home.appendingPathComponent(".codex", isDirectory: true),
            stateDirectory: home
                .appendingPathComponent("Library/Application Support", isDirectory: true)
                .appendingPathComponent("AgentSync", isDirectory: true),
            sessionLookbackDays: 14,
            maximumImportedSessions: 10
        )
    }
}
