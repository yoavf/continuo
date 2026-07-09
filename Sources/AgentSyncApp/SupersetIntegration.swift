import Foundation

enum SupersetConnectionStatus: Equatable, Sendable {
    case ready
    case cliMissing
    case loginRequired
    case v2Required

    var isReady: Bool {
        self == .ready
    }

    var title: String {
        switch self {
        case .ready:
            return "Superset ready"
        case .cliMissing:
            return "Superset CLI not found"
        case .loginRequired:
            return "Sign in to Superset CLI"
        case .v2Required:
            return "Enable Superset v2"
        }
    }

    var guidance: String? {
        switch self {
        case .ready:
            return nil
        case .cliMissing:
            return "Open Superset once to install its command-line helper, then check again."
        case .loginRequired:
            return "In Terminal, run ~/.superset/bin/superset auth login, then check again."
        case .v2Required:
            return "In Superset, open Settings → Experimental and turn on Try Superset v2. Then return here and confirm it is enabled."
        }
    }
}

struct SupersetWorkspace: Decodable, Equatable, Sendable {
    let id: String
    let name: String
    let worktreePath: String
}

struct SupersetTerminal: Decodable, Equatable, Sendable {
    let terminalId: String
}

struct SupersetProject: Decodable, Equatable, Sendable {
    let id: String
    let name: String
    let path: String
    let repoCloneURL: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case path
        case repoCloneURL = "repoCloneUrl"
    }
}

struct SupersetProjectCreation: Decodable, Equatable, Sendable {
    let projectId: String
}

struct SupersetWorkspaceCreation: Decodable, Sendable {
    let workspace: SupersetWorkspace
}

struct SupersetWorkspaceResolution: Equatable, Sendable {
    let workspace: SupersetWorkspace
    let workingDirectory: String
}

private struct SupersetGitContext {
    let worktreeRoot: String
    let repositoryRoot: String
    let branch: String
    let remoteURL: String?
}

enum SupersetIntegrationError: LocalizedError {
    case cliMissing
    case commandFailed(String)
    case gitContextUnavailable
    case invalidResponse
    case openFailed

    var errorDescription: String? {
        switch self {
        case .cliMissing:
            return "Open Superset once to finish setup, then try again."
        case .commandFailed(let detail):
            return detail.isEmpty ? "Superset is not ready." : "Superset is not ready: \(detail)"
        case .gitContextUnavailable:
            return "Continuo could not identify this session's Git branch for Superset."
        case .invalidResponse:
            return "Superset returned an invalid response."
        case .openFailed:
            return "Superset could not open the new terminal."
        }
    }
}

enum SupersetIntegration {
    static func connectionStatus(
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        v2Enabled: Bool = Prefs.supersetV2Enabled
    ) -> SupersetConnectionStatus {
        guard executableURL(
            fileManager: fileManager,
            homeDirectory: homeDirectory,
            environment: environment
        ) != nil else {
            return .cliMissing
        }
        if normalized(environment["SUPERSET_API_KEY"]) == nil {
            let home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
            let configURL = supersetHome(homeDirectory: home, environment: environment)
                .appendingPathComponent("config.json")
            guard let data = try? Data(contentsOf: configURL),
                  let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  normalized(config["organizationId"] as? String) != nil else {
                return .loginRequired
            }
        }
        return v2Enabled ? .ready : .v2Required
    }

    static func executableURL(
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        let stateHome = supersetHome(homeDirectory: home, environment: environment)
        var candidates = [
            stateHome.appendingPathComponent("bin/superset"),
            home.appendingPathComponent("superset/bin/superset"),
            URL(fileURLWithPath: "/opt/homebrew/bin/superset"),
            URL(fileURLWithPath: "/usr/local/bin/superset")
        ]
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true)
                    .appendingPathComponent("superset")
            })
        }
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    static func workspace(
        containing workingDirectory: String,
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> SupersetWorkspaceResolution {
        guard let executable = executableURL(
            fileManager: fileManager,
            homeDirectory: homeDirectory,
            environment: environment
        ) else {
            throw SupersetIntegrationError.cliMissing
        }
        let data = try run(
            executable,
            arguments: ["workspaces", "list", "--local", "--json"],
            environment: environment
        )
        let workspaces = try decodeWorkspaces(data)
        if let workspace = matchingWorkspace(containing: workingDirectory, in: workspaces) {
            return SupersetWorkspaceResolution(
                workspace: workspace,
                workingDirectory: workingDirectory
            )
        }

        let git = try gitContext(at: workingDirectory, environment: environment)
        let projectsData = try run(
            executable,
            arguments: ["projects", "list", "--local", "--json"],
            environment: environment
        )
        let projects = try decodeProjects(projectsData)
        let localProject = matchingProject(
            repositoryRoot: git.repositoryRoot,
            worktreeRoot: git.worktreeRoot,
            in: projects
        )
        let projectID: String
        let projectWasConfigured: Bool
        if let localProject {
            projectID = localProject.id
            projectWasConfigured = false
        } else if let cloudProject = matchingUnconfiguredProject(git: git, in: projects) {
            _ = try run(
                executable,
                arguments: [
                    "projects", "setup", cloudProject.id,
                    "--path", git.repositoryRoot,
                    "--local",
                    "--json"
                ],
                environment: environment
            )
            projectID = cloudProject.id
            projectWasConfigured = true
        } else {
            let creationData = try run(
                executable,
                arguments: [
                    "projects", "create",
                    "--name", repositoryName(for: git.repositoryRoot),
                    "--import", git.repositoryRoot,
                    "--local",
                    "--json"
                ],
                environment: environment
            )
            projectID = try decodeProjectCreation(creationData).projectId
            projectWasConfigured = true
        }

        if projectWasConfigured {
            let refreshedWorkspaceData = try run(
                executable,
                arguments: ["workspaces", "list", "--local", "--json"],
                environment: environment
            )
            let refreshedWorkspaces = try decodeWorkspaces(refreshedWorkspaceData)
            if let workspace = matchingWorkspace(
                containing: workingDirectory,
                in: refreshedWorkspaces
            ) {
                return SupersetWorkspaceResolution(
                    workspace: workspace,
                    workingDirectory: workingDirectory
                )
            }
        }

        let creationData = try run(
            executable,
            arguments: [
                "workspaces", "create",
                "--project", projectID,
                "--name", git.branch,
                "--branch", git.branch,
                "--local",
                "--json"
            ],
            environment: environment
        )
        let workspace = try decodeWorkspaceCreation(creationData)
        return SupersetWorkspaceResolution(
            workspace: workspace,
            workingDirectory: launchDirectory(
                original: workingDirectory,
                git: git,
                workspace: workspace,
                fileManager: fileManager
            )
        )
    }

    static func createTerminal(
        workspaceID: String,
        workingDirectory: String,
        command: String,
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> SupersetTerminal {
        guard let executable = executableURL(
            fileManager: fileManager,
            homeDirectory: homeDirectory,
            environment: environment
        ) else {
            throw SupersetIntegrationError.cliMissing
        }
        let data = try run(
            executable,
            arguments: [
                "terminals", "create",
                "--workspace", workspaceID,
                "--command", command,
                "--cwd", workingDirectory,
                "--json"
            ],
            environment: environment
        )
        guard let terminal = try? JSONDecoder().decode(SupersetTerminal.self, from: data) else {
            throw SupersetIntegrationError.invalidResponse
        }
        return terminal
    }

    static func terminalURL(workspaceID: String, terminalID: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "superset"
        components.host = "v2-workspace"
        components.path = "/\(workspaceID)"
        components.queryItems = [
            URLQueryItem(name: "terminalId", value: terminalID),
            URLQueryItem(name: "focusRequestId", value: UUID().uuidString)
        ]
        guard let url = components.url else {
            throw SupersetIntegrationError.openFailed
        }
        return url
    }

    static func decodeWorkspaces(_ data: Data) throws -> [SupersetWorkspace] {
        if String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "null" {
            return []
        }
        guard let workspaces = try? JSONDecoder().decode([SupersetWorkspace].self, from: data) else {
            throw SupersetIntegrationError.invalidResponse
        }
        return workspaces
    }

    static func decodeProjects(_ data: Data) throws -> [SupersetProject] {
        if String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "null" {
            return []
        }
        guard let projects = try? JSONDecoder().decode([SupersetProject].self, from: data) else {
            throw SupersetIntegrationError.invalidResponse
        }
        return projects
    }

    static func decodeWorkspaceCreation(_ data: Data) throws -> SupersetWorkspace {
        if let result = try? JSONDecoder().decode(SupersetWorkspaceCreation.self, from: data) {
            return result.workspace
        }
        if let workspace = try? JSONDecoder().decode(SupersetWorkspace.self, from: data) {
            return workspace
        }
        throw SupersetIntegrationError.invalidResponse
    }

    static func decodeProjectCreation(_ data: Data) throws -> SupersetProjectCreation {
        guard let project = try? JSONDecoder().decode(SupersetProjectCreation.self, from: data) else {
            throw SupersetIntegrationError.invalidResponse
        }
        return project
    }

    static func matchingWorkspace(
        containing workingDirectory: String,
        in workspaces: [SupersetWorkspace]
    ) -> SupersetWorkspace? {
        let cwd = normalizedPath(workingDirectory)
        return workspaces
            .filter { workspace in
                let root = normalizedPath(workspace.worktreePath)
                return cwd == root || cwd.hasPrefix(root + "/")
            }
            .max { lhs, rhs in
                normalizedPath(lhs.worktreePath).count < normalizedPath(rhs.worktreePath).count
            }
    }

    static func matchingProject(
        repositoryRoot: String,
        worktreeRoot: String,
        in projects: [SupersetProject]
    ) -> SupersetProject? {
        let roots = Set([normalizedPath(repositoryRoot), normalizedPath(worktreeRoot)])
        return projects.first { project in
            project.path != "-" && roots.contains(normalizedPath(project.path))
        }
    }

    private static func matchingUnconfiguredProject(
        git: SupersetGitContext,
        in projects: [SupersetProject]
    ) -> SupersetProject? {
        let unconfigured = projects.filter { $0.path == "-" }
        if let remote = normalizedGitRemote(git.remoteURL),
           let match = unconfigured.first(where: {
               normalizedGitRemote($0.repoCloneURL) == remote
           }) {
            return match
        }

        let name = repositoryName(for: git.repositoryRoot)
        let nameMatches = unconfigured.filter {
            $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        return nameMatches.count == 1 ? nameMatches[0] : nil
    }

    private static func gitContext(
        at workingDirectory: String,
        environment: [String: String]
    ) throws -> SupersetGitContext {
        do {
            let worktreeRoot = try gitOutput(
                ["rev-parse", "--show-toplevel"],
                at: workingDirectory,
                environment: environment
            )
            let commonDirectory = try gitOutput(
                ["rev-parse", "--path-format=absolute", "--git-common-dir"],
                at: workingDirectory,
                environment: environment
            )
            let branch = try gitOutput(
                ["symbolic-ref", "--short", "HEAD"],
                at: workingDirectory,
                environment: environment
            )
            let remoteURL = try? gitOutput(
                ["config", "--get", "remote.origin.url"],
                at: workingDirectory,
                environment: environment
            )
            let commonURL = URL(fileURLWithPath: commonDirectory, isDirectory: true)
            let repositoryRoot = commonURL.lastPathComponent == ".git"
                ? commonURL.deletingLastPathComponent().path
                : worktreeRoot
            return SupersetGitContext(
                worktreeRoot: normalizedPath(worktreeRoot),
                repositoryRoot: normalizedPath(repositoryRoot),
                branch: branch,
                remoteURL: remoteURL
            )
        } catch {
            throw SupersetIntegrationError.gitContextUnavailable
        }
    }

    private static func gitOutput(
        _ arguments: [String],
        at workingDirectory: String,
        environment: [String: String]
    ) throws -> String {
        let data = try run(
            URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            environment: environment,
            currentDirectory: URL(fileURLWithPath: workingDirectory, isDirectory: true)
        )
        guard let output = String(data: data, encoding: .utf8),
              let normalized = normalized(output) else {
            throw SupersetIntegrationError.gitContextUnavailable
        }
        return normalized
    }

    private static func launchDirectory(
        original: String,
        git: SupersetGitContext,
        workspace: SupersetWorkspace,
        fileManager: FileManager
    ) -> String {
        let original = normalizedPath(original)
        let workspaceRoot = normalizedPath(workspace.worktreePath)
        if original == workspaceRoot || original.hasPrefix(workspaceRoot + "/") {
            return original
        }
        let prefix = git.worktreeRoot + "/"
        guard original.hasPrefix(prefix) else {
            return workspaceRoot
        }
        let relative = String(original.dropFirst(prefix.count))
        let candidate = URL(fileURLWithPath: workspaceRoot, isDirectory: true)
            .appendingPathComponent(relative, isDirectory: true)
            .path
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory)
            && isDirectory.boolValue ? candidate : workspaceRoot
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static func repositoryName(for path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
    }

    private static func normalizedGitRemote(_ remote: String?) -> String? {
        guard var remote = normalized(remote) else { return nil }
        if remote.hasPrefix("git@"), let colon = remote.firstIndex(of: ":") {
            let hostStart = remote.index(remote.startIndex, offsetBy: 4)
            remote = String(remote[hostStart..<colon]) + "/" + remote[remote.index(after: colon)...]
        } else if let components = URLComponents(string: remote),
                  let host = components.host {
            remote = host + components.path
        }
        remote = remote.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if remote.hasSuffix(".git") {
            remote.removeLast(4)
        }
        return remote.lowercased()
    }

    private static func supersetHome(
        homeDirectory: URL,
        environment: [String: String]
    ) -> URL {
        if let override = normalized(environment["SUPERSET_HOME_DIR"]) {
            return URL(
                fileURLWithPath: NSString(string: override).expandingTildeInPath,
                isDirectory: true
            )
        }
        return homeDirectory.appendingPathComponent(".superset", isDirectory: true)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL? = nil
    ) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectory
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw SupersetIntegrationError.commandFailed(error.localizedDescription)
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errorData + data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw SupersetIntegrationError.commandFailed(detail)
        }
        return data
    }
}
