import Foundation
import Testing
@testable import AgentSyncApp

@Suite("CMUX integration")
struct CMUXIntegrationTests {
    @Test("current CMUX authentication response is accepted")
    func authenticationResponse() {
        #expect(CMUXSocketClient.isSuccessfulAuthResponse("OK"))
        #expect(CMUXSocketClient.isSuccessfulAuthResponse("OK: Authenticated"))
        #expect(!CMUXSocketClient.isSuccessfulAuthResponse("ERROR: Authentication required"))
    }

    @Test("password mode requires a configured password")
    func passwordMissing() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeConfig(#"{"automation":{"socketControlMode":"password"}}"#, home: home)

        #expect(CMUXIntegration.connectionStatus(homeDirectory: home, environment: [:]) == .passwordMissing)
    }

    @Test("current CMUX password file enables the integration")
    func currentPasswordFile() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeConfig(#"{"automation":{"socketControlMode":"password"}}"#, home: home)
        let passwordURL = home.appendingPathComponent(".local/state/cmux/socket-control-password")
        try FileManager.default.createDirectory(
            at: passwordURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("  local-secret\n".utf8).write(to: passwordURL)

        #expect(CMUXIntegration.connectionStatus(homeDirectory: home, environment: [:]) == .ready)
        #expect(CMUXIntegration.socketPassword(homeDirectory: home, environment: [:]) == "local-secret")
    }

    @Test("open local access needs no password")
    func allowAll() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeConfig(#"{"automation":{"socketControlMode":"allowAll"}}"#, home: home)

        #expect(CMUXIntegration.connectionStatus(homeDirectory: home, environment: [:]) == .ready)
    }

    @Test("CMUX-only and disabled modes remain actionable")
    func restrictedModes() throws {
        let cmuxOnlyHome = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: cmuxOnlyHome) }
        try writeConfig(#"{"automation":{"socketControlMode":"cmuxOnly"}}"#, home: cmuxOnlyHome)
        #expect(CMUXIntegration.connectionStatus(homeDirectory: cmuxOnlyHome, environment: [:]) == .restricted)

        let offHome = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: offHome) }
        try writeConfig(#"{"automation":{"socketControlMode":"off"}}"#, home: offHome)
        #expect(CMUXIntegration.connectionStatus(homeDirectory: offHome, environment: [:]) == .disabled)
    }

    @Test("legacy plaintext passwords remain supported")
    func legacyConfigPassword() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeConfig(
            #"{"automation":{"socketControlMode":"password","socketPassword":"legacy-secret"}}"#,
            home: home
        )

        #expect(CMUXIntegration.socketPassword(homeDirectory: home, environment: [:]) == "legacy-secret")
        #expect(CMUXIntegration.connectionStatus(homeDirectory: home, environment: [:]) == .ready)
    }

    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-cmux-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeConfig(_ text: String, home: URL) throws {
        let url = home.appendingPathComponent(".config/cmux/cmux.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }
}
