import Foundation
import Testing
@testable import AgentSyncApp

@Suite("Superset integration")
struct SupersetIntegrationTests {
    @Test("Superset setup alerts preserve the actual failure")
    func setupAlertDetail() throws {
        let alert = try #require(
            TerminalLaunchError.supersetSetupRequired("Repository is not registered.")
                .setupAlert
        )

        #expect(alert.terminal == .superset)
        #expect(alert.message == "Repository is not registered.")
    }

    @Test("a missing workspace is adopted for an existing local project")
    func createsMissingWorkspace() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-superset-create-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let repository = home.appendingPathComponent("repo", isDirectory: true)
        try initializeGitRepository(repository)

        let executable = home.appendingPathComponent(".superset/bin/superset")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let projectJSON = #"[{"id":"project-1","name":"Repo","path":"\#(repository.path)"}]"#
        let creationJSON = #"{"workspace":{"id":"workspace-1","name":"main","worktreePath":"\#(repository.path)"}}"#
        let script = """
        #!/bin/sh
        if [ "$1" = "workspaces" ] && [ "$2" = "list" ]; then
          printf '%s\\n' '[]'
        elif [ "$1" = "projects" ] && [ "$2" = "list" ]; then
          printf '%s\\n' '\(projectJSON)'
        elif [ "$1" = "workspaces" ] && [ "$2" = "create" ]; then
          printf '%s\\n' '\(creationJSON)'
        else
          exit 1
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let resolution = try SupersetIntegration.workspace(
            containing: repository.path,
            homeDirectory: home,
            environment: [:]
        )

        #expect(resolution.workspace.id == "workspace-1")
        #expect(resolution.workingDirectory == repository.path)
    }

    @Test("a missing Superset project is created automatically")
    func createsMissingCurrentProject() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-superset-project-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let repository = home.appendingPathComponent("repo", isDirectory: true)
        try initializeGitRepository(repository)

        let executable = home.appendingPathComponent(".superset/bin/superset")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let projectCreated = home.appendingPathComponent("project-created").path
        let workspaceJSON = #"[{"id":"workspace-main","name":"main","worktreePath":"\#(repository.path)"}]"#
        let projectCreationJSON = #"{"projectId":"project-1","repoPath":"\#(repository.path)","mainWorkspaceId":"workspace-main"}"#
        let script = """
        #!/bin/sh
        if [ "$1" = "workspaces" ] && [ "$2" = "list" ]; then
          if [ -f '\(projectCreated)' ]; then
            printf '%s\\n' '\(workspaceJSON)'
          else
            printf '%s\\n' '[]'
          fi
        elif [ "$1" = "projects" ] && [ "$2" = "list" ]; then
          printf '%s\\n' '[]'
        elif [ "$1" = "projects" ] && [ "$2" = "create" ]; then
          touch '\(projectCreated)'
          printf '%s\\n' '\(projectCreationJSON)'
        else
          exit 1
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let resolution = try SupersetIntegration.workspace(
            containing: repository.path,
            homeDirectory: home,
            environment: [:]
        )

        #expect(resolution.workspace.id == "workspace-main")
        #expect(resolution.workingDirectory == repository.path)
        #expect(FileManager.default.fileExists(atPath: projectCreated))
    }

    @Test("an existing current cloud project is set up locally instead of duplicated")
    func setsUpExistingCloudProject() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-superset-setup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let repository = home.appendingPathComponent("repo", isDirectory: true)
        try initializeGitRepository(repository)
        try runGit(
            ["remote", "add", "origin", "git@github.com:base44-dev/repo.git"],
            at: repository
        )

        let executable = home.appendingPathComponent(".superset/bin/superset")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let setupComplete = home.appendingPathComponent("setup-complete").path
        let projectJSON = #"[{"id":"project-cloud","name":"Repo","path":"-","repoCloneUrl":"https://github.com/base44-dev/repo"}]"#
        let workspaceJSON = #"[{"id":"workspace-main","name":"main","worktreePath":"\#(repository.path)"}]"#
        let script = """
        #!/bin/sh
        if [ "$1" = "workspaces" ] && [ "$2" = "list" ]; then
          if [ -f '\(setupComplete)' ]; then
            printf '%s\\n' '\(workspaceJSON)'
          else
            printf '%s\\n' '[]'
          fi
        elif [ "$1" = "projects" ] && [ "$2" = "list" ]; then
          printf '%s\\n' '\(projectJSON)'
        elif [ "$1" = "projects" ] && [ "$2" = "setup" ] && [ "$3" = "project-cloud" ]; then
          touch '\(setupComplete)'
          printf '%s\\n' '{}'
        elif [ "$1" = "projects" ] && [ "$2" = "create" ]; then
          exit 9
        else
          exit 1
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let resolution = try SupersetIntegration.workspace(
            containing: repository.path,
            homeDirectory: home,
            environment: [:]
        )

        #expect(resolution.workspace.id == "workspace-main")
        #expect(FileManager.default.fileExists(atPath: setupComplete))
    }

    @Test("the desktop app's managed CLI is detected")
    func managedCLI() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-superset-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let executable = home.appendingPathComponent(".superset/bin/superset")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        #expect(
            SupersetIntegration.executableURL(
                homeDirectory: home,
                environment: [:]
            ) == executable
        )
        #expect(
            SupersetIntegration.connectionStatus(
                homeDirectory: home,
                environment: [:],
                v2Enabled: true
            ) == .loginRequired
        )

        let config = home.appendingPathComponent(".superset/config.json")
        try Data(#"{"organizationId":"organization-1"}"#.utf8).write(to: config)
        #expect(
            SupersetIntegration.connectionStatus(
                homeDirectory: home,
                environment: [:],
                v2Enabled: false
            ) == .v2Required
        )
        #expect(
            SupersetIntegration.connectionStatus(
                homeDirectory: home,
                environment: [:],
                v2Enabled: true
            ) == .ready
        )
        #expect(
            SupersetIntegration.connectionStatus(
                homeDirectory: home,
                environment: ["SUPERSET_API_KEY": "test-key"],
                v2Enabled: true
            ) == .ready
        )
    }

    @Test("current workspace JSON is decoded")
    func workspaceJSON() throws {
        let data = Data(
            #"[{"id":"workspace-1","name":"Agent Sync","worktreePath":"/tmp/agent-sync","branch":"main","projectId":"project-1"}]"#.utf8
        )

        #expect(
            try SupersetIntegration.decodeWorkspaces(data) == [
                SupersetWorkspace(
                    id: "workspace-1",
                    name: "Agent Sync",
                    worktreePath: "/tmp/agent-sync"
                )
            ]
        )
    }

    @Test("the most specific workspace containing the session folder wins")
    func workspaceMatching() {
        let workspaces = [
            SupersetWorkspace(id: "parent", name: "Parent", worktreePath: "/tmp/code"),
            SupersetWorkspace(id: "exact", name: "Exact", worktreePath: "/tmp/code/continuo")
        ]

        let match = SupersetIntegration.matchingWorkspace(
            containing: "/tmp/code/continuo/Sources",
            in: workspaces
        )

        #expect(match?.id == "exact")
    }

    @Test("a sibling path does not match a workspace prefix")
    func siblingDoesNotMatch() {
        let workspaces = [
            SupersetWorkspace(id: "one", name: "One", worktreePath: "/tmp/code/app")
        ]

        #expect(
            SupersetIntegration.matchingWorkspace(
                containing: "/tmp/code/application",
                in: workspaces
            ) == nil
        )
    }

    @Test("empty workspace output is accepted")
    func emptyWorkspaces() throws {
        #expect(try SupersetIntegration.decodeWorkspaces(Data("null\n".utf8)).isEmpty)
    }

    @Test("terminal deep links focus the created session")
    func terminalDeepLink() throws {
        let url = try SupersetIntegration.terminalURL(
            workspaceID: "workspace-1",
            terminalID: "terminal-1"
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(components.scheme == "superset")
        #expect(components.host == "v2-workspace")
        #expect(components.path == "/workspace-1")
        #expect(
            components.queryItems?.contains {
                $0.name == "terminalId" && $0.value == "terminal-1"
            } == true
        )
        #expect(components.queryItems?.contains(where: { $0.name == "focusRequestId" }) == true)
    }

    private func initializeGitRepository(_ url: URL) throws {
        try runGit(["init", "-b", "main", url.path], at: nil)
    }

    private func runGit(_ arguments: [String], at directory: URL?) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
