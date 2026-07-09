import AgentSyncCore
import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            GeneralSettingsTab(model: model)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
            ModelSettingsTab(model: model)
                .tabItem {
                    Label("Models", systemImage: "arrow.left.arrow.right")
                }
        }
        .frame(width: 600)
        .frame(minHeight: 460)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @ObservedObject var model: AppModel

    @AppStorage(Prefs.preferredTerminalKey) private var preferredTerminal = TerminalApp.terminal.rawValue
    @AppStorage(Prefs.claudeHomeKey) private var claudeHomePath = Prefs.claudeHomePath
    @AppStorage(Prefs.codexHomeKey) private var codexHomePath = Prefs.codexHomePath
    @AppStorage(Prefs.opencodeHomeKey) private var opencodeHomePath = Prefs.opencodeHomePath
    @AppStorage(Prefs.stateDirectoryKey) private var stateDirectoryPath = Prefs.stateDirectoryPath

    @AppStorage(Prefs.hotkeyEnabledKey) private var hotkeyEnabled = true
    @AppStorage(Prefs.supersetV2EnabledKey) private var supersetV2Enabled = false
    @State private var installMessage: String?
    @State private var cmuxStatus = TerminalLauncher.cmuxConnectionStatus
    @State private var supersetStatus = TerminalLauncher.supersetConnectionStatus
    @State private var setupInstructionsTerminal: TerminalApp?

    var body: some View {
        Form {
            Section {
                Toggle("Open the picker with ⌥⌘S", isOn: $hotkeyEnabled)
                    .onChange(of: hotkeyEnabled) {
                        model.applyHotkeySetting()
                    }
            } footer: {
                Text("Opens a floating picker from anywhere, like Spotlight. Esc closes it.")
            }

            Section {
                Picker("Open sessions in", selection: $preferredTerminal) {
                    ForEach(TerminalApp.installed) { terminal in
                        Text(terminal.displayName).tag(terminal.rawValue)
                    }
                }
                .pickerStyle(.menu)
                if preferredTerminal == TerminalApp.cmux.rawValue {
                    IntegrationStatusRow(title: cmuxStatus.title, isReady: cmuxStatus.isReady) {
                        setupInstructionsTerminal = .cmux
                    } onRefresh: {
                        cmuxStatus = TerminalLauncher.cmuxConnectionStatus
                    }
                } else if preferredTerminal == TerminalApp.superset.rawValue {
                    IntegrationStatusRow(
                        title: supersetStatus.title,
                        isReady: supersetStatus.isReady
                    ) {
                        setupInstructionsTerminal = .superset
                    } onRefresh: {
                        supersetStatus = TerminalLauncher.supersetConnectionStatus
                    }
                }
            } footer: {
                if preferredTerminal == TerminalApp.cmux.rawValue {
                    Text(
                        cmuxStatus.guidance
                            ?? "CMUX opens resumed sessions as named workspaces."
                    )
                } else if preferredTerminal == TerminalApp.superset.rawValue {
                    Text(
                        supersetStatus.guidance
                            ?? "Continuo opens resumed sessions in the matching Superset workspace, creating the project or workspace when needed."
                    )
                } else {
                    Text("Only installed terminals are listed.")
                }
            }

            Section {
                PathRow(title: "Claude Code home", path: $claudeHomePath, defaultPath: Prefs.production.claudeHome.path)
                PathRow(title: "Codex home", path: $codexHomePath, defaultPath: Prefs.production.codexHome.path)
                PathRow(title: "OpenCode data", path: $opencodeHomePath, defaultPath: Prefs.production.opencodeHome.path)
                PathRow(title: "Bridge state", path: $stateDirectoryPath, defaultPath: Prefs.production.stateDirectory.path)
            } footer: {
                Text("Native transcripts are read-only inputs. Continuo writes only its own mirror files, tracked in bridge-state.json.")
            }

            Section {
                LabeledContent("Install in /Applications") {
                    Button("Install…") {
                        installMessage = installInApplications()
                    }
                }
                if let installMessage {
                    Text(installMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: claudeHomePath) { model.refresh() }
        .onChange(of: codexHomePath) { model.refresh() }
        .onChange(of: opencodeHomePath) { model.refresh() }
        .onChange(of: stateDirectoryPath) { model.refresh() }
        .onChange(of: preferredTerminal) {
            cmuxStatus = TerminalLauncher.cmuxConnectionStatus
            supersetStatus = TerminalLauncher.supersetConnectionStatus
        }
        .onAppear {
            cmuxStatus = TerminalLauncher.cmuxConnectionStatus
            supersetStatus = TerminalLauncher.supersetConnectionStatus
        }
        .alert(item: $setupInstructionsTerminal) { terminal in
            setupAlert(for: terminal)
        }
    }

    private func setupAlert(for terminal: TerminalApp) -> Alert {
        guard terminal == .superset else {
            return Alert(
                title: Text("Set up \(terminal.displayName)"),
                message: Text(terminal.setupInstructions),
                dismissButton: .cancel(Text("Got it"))
            )
        }
        let message = supersetStatus.guidance ?? terminal.setupInstructions
        if supersetStatus == .v2Required {
            return Alert(
                title: Text(supersetStatus.title),
                message: Text(message),
                primaryButton: .default(Text("I enabled Superset v2")) {
                    supersetV2Enabled = true
                    supersetStatus = TerminalLauncher.supersetConnectionStatus
                },
                secondaryButton: .cancel()
            )
        }
        return Alert(
            title: Text(supersetStatus.title),
            message: Text(message),
            dismissButton: .cancel(Text("Got it"))
        )
    }

    private func installInApplications() -> String {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            return "Build the app bundle first with Scripts/package-app.sh."
        }
        let destination = URL(fileURLWithPath: "/Applications", isDirectory: true)
            .appendingPathComponent(bundleURL.lastPathComponent, isDirectory: true)
        if bundleURL.standardizedFileURL.path == destination.standardizedFileURL.path {
            return "Already running from Applications."
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
            return "\(destination.lastPathComponent) already exists in Applications."
        }
        do {
            try FileManager.default.copyItem(at: bundleURL, to: destination)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
            return "Installed \(destination.lastPathComponent) in Applications."
        } catch {
            return "Install failed: \(error.localizedDescription)"
        }
    }
}

private struct IntegrationStatusRow: View {
    let title: String
    let isReady: Bool
    let onConfigure: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(isReady ? .green : .orange)
            Spacer()
            if !isReady {
                Button("Set up…", action: onConfigure)
            }
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Check connection again")
            .accessibilityLabel("Check connection again")
        }
        .font(.callout)
    }
}

/// Paths are auto-detected and rarely change: shown as plain text, with the
/// change/reset controls only appearing on hover.
private struct PathRow: View {
    var title: String
    @Binding var path: String
    var defaultPath: String

    @State private var isHovering = false

    private var exists: Bool {
        FileManager.default.fileExists(atPath: NSString(string: path).expandingTildeInPath)
    }

    private var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                if isHovering {
                    if path != defaultPath {
                        Button {
                            path = defaultPath
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderless)
                        .help("Reset to default")
                    }
                    Button {
                        choose()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Choose a different folder")
                }
                Text(displayPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 300, alignment: .trailing)
                Image(systemName: exists ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(exists ? .green : .orange)
                    .help(exists ? "Folder exists" : "Folder not found")
            }
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = "Choose \(title)"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }
}

// MARK: - Models

private struct ModelSettingsTab: View {
    @ObservedObject var model: AppModel

    @AppStorage(Prefs.codexTargetModelKey) private var codexTargetModel = Prefs.codexTargetModel
    @AppStorage(Prefs.claudeTargetModelKey) private var claudeTargetModel = Prefs.claudeTargetModel
    @AppStorage(Prefs.opencodeResumeModelKey) private var opencodeResumeModel = ""
    @AppStorage(Prefs.transferModeKey) private var transferMode = ResumeMode.auto.rawValue

    @State private var pairs = Prefs.modelPairs()

    /// Models actually seen in OpenCode's history — providers there are
    /// configured and authenticated, so `-m` can't fail at launch.
    private var opencodeModels: [String] {
        model.observedModels[.opencode] ?? []
    }

    private var opencodeCurrentChoice: String {
        model.sessions.first { $0.preview.provider == .opencode }?.preview.models.first ?? "its most recent model"
    }

    private static let curatedClaudeModels = ["claude-sonnet-5", "claude-opus-4-8", "claude-fable-5", "claude-haiku-4-5"]
    private static let curatedCodexModels = ["gpt-5.5", "gpt-5.5-codex", "gpt-5.4", "gpt-5-mini"]

    /// Claude models actually seen in transcripts (mirror leakage of the other
    /// family filtered out), plus any already-paired ones.
    private var claudeModels: [String] {
        merged(
            observed: (model.observedModels[.claude] ?? []).filter(Prefs.isClaudeFamilyModel),
            extra: Array(pairs.keys).sorted()
        )
    }

    private var codexOptions: [String] {
        merged(
            observed: (model.observedModels[.codex] ?? []).filter { !Prefs.isClaudeFamilyModel($0) },
            extra: Self.curatedCodexModels + [codexTargetModel]
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("Carry over", selection: $transferMode) {
                    Text("Auto — full when it fits, brief otherwise").tag(ResumeMode.auto.rawValue)
                    Text("Always full transcript (trimmed if needed)").tag(ResumeMode.full.rawValue)
                    Text("Always handoff brief").tag(ResumeMode.handoff.rawValue)
                }
                .pickerStyle(.menu)
            } header: {
                Text("Transfer")
            } footer: {
                Text("A handoff brief is a compact summary plus the most recent turns, ending on your latest request.")
            }

            Section {
                if claudeModels.isEmpty {
                    Text("No models observed yet — open the picker once to scan sessions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(claudeModels, id: \.self) { claudeModel in
                    Picker("\(claudeModel)  ⇄", selection: pairBinding(for: claudeModel)) {
                        Text("Default (\(codexTargetModel))").tag("")
                        Divider()
                        ForEach(codexOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                }
            } header: {
                Text("Model pairs")
            } footer: {
                Text("Pairs apply in both directions: a Claude session's Fable turns continue in Codex as its partner, and that Codex model's turns continue in Claude as Fable. Matched per assistant message, so multi-model sessions map each model separately. Listed models come from your recent sessions.")
            }

            Section {
                ModelField(
                    title: "Unpaired Claude models →",
                    value: $codexTargetModel,
                    suggestions: Self.curatedCodexModels
                )
                ModelField(
                    title: "Unpaired Codex models →",
                    value: $claudeTargetModel,
                    suggestions: Self.curatedClaudeModels
                )
            } header: {
                Text("Defaults")
            } footer: {
                Text("The original model always stays recorded in the conversation metadata.")
            }

            Section {
                Picker("Resume in OpenCode using", selection: $opencodeResumeModel) {
                    Text("OpenCode's own choice (currently \(opencodeCurrentChoice))").tag("")
                    if !opencodeModels.isEmpty {
                        Divider()
                        ForEach(opencodeModels, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("OpenCode")
            } footer: {
                Text("Only models from your OpenCode history are listed — their providers are already set up there.")
            }
        }
        .formStyle(.grouped)
    }

    private func pairBinding(for claudeModel: String) -> Binding<String> {
        Binding(
            get: { pairs[claudeModel] ?? "" },
            set: { newValue in
                if newValue.isEmpty {
                    pairs.removeValue(forKey: claudeModel)
                } else {
                    pairs[claudeModel] = newValue
                }
                Prefs.setModelPairs(pairs)
            }
        )
    }

    private func merged(observed: [String], extra: [String]) -> [String] {
        var result: [String] = []
        for value in observed + extra where !value.isEmpty && !result.contains(value) {
            result.append(value)
        }
        return result
    }
}

private struct ModelField: View {
    var title: String
    @Binding var value: String
    var suggestions: [String]

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                TextField(title, text: $value)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .font(.system(.body, design: .monospaced))
                    .labelsHidden()
                    .frame(width: 220)
                Menu {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button(suggestion) {
                            value = suggestion
                        }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Suggested models")
            }
        }
    }
}
