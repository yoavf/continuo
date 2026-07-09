import AgentSyncCore
import SwiftUI

struct SessionPickerView: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @State private var selectedItem: SessionItem?

    /// Six most recent conversations by default; searching reaches the whole
    /// scanned set. Every query word must match something — title, project, or
    /// agent name — so "codex gemini" finds Codex sessions about gemini as
    /// well as any session literally titled "codex gemini".
    private var filteredSessions: [SessionItem] {
        let tokens = query.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else {
            return Array(model.sessions.prefix(6))
        }
        return model.sessions.filter { item in
            let haystack = [
                item.displayTitle,
                item.preview.projectName,
                item.preview.provider.displayName,
                (item.mirrorOrigin ?? item.preview.provider).displayName
            ]
            return tokens.allSatisfy { token in
                haystack.contains { $0.localizedCaseInsensitiveContains(token) }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let item = selectedItem {
                ContinueView(model: model, item: item) {
                    selectedItem = nil
                }
            } else {
                header
                Divider()

                ForEach(model.setupProblems, id: \.self) { problem in
                    problemBanner(problem)
                }

                sessionList
            }

            if model.status != .idle {
                Divider()
                StatusBar(status: model.status, onDismiss: model.clearStatus)
            }
        }
        .frame(width: 480)
        .onAppear {
            model.refresh()
        }
        .alert(item: $model.terminalSetupAlert) { setupAlert in
            Alert(
                title: Text("\(setupAlert.terminal.displayName) needs setup"),
                message: Text(setupAlert.message),
                primaryButton: .default(Text("Open Continuo Settings")) {
                    AppDelegate.openSettings()
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search sessions", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))

            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(model.isRefreshing)
            .help("Rescan recent sessions")

            Button {
                AppDelegate.openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quit Continuo")
        }
        .padding(10)
    }

    @ViewBuilder
    private var sessionList: some View {
        if filteredSessions.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: model.isRefreshing ? "clock" : "moon.zzz")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 42)
        } else {
            HStack {
                Text(query.isEmpty ? "Recent sessions" : "Results")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 2)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(filteredSessions) { item in
                        SessionRow(
                            item: item,
                            isLaunching: model.launchingID == item.id,
                            isDisabled: model.launchingID != nil
                        ) {
                            selectedItem = item
                        }
                    }
                }
                .padding(6)
            }
            // A ScrollView has no intrinsic height, and the MenuBarExtra window
            // sizes to ideal height — without an explicit frame it collapses to
            // zero rows. Size to content, capped for long search results.
            .frame(height: min(CGFloat(filteredSessions.count) * 71 + 12, 500))

            if query.isEmpty, model.sessions.count > 6 {
                Text("\(model.sessions.count - 6) more in the last two weeks — type to search")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
    }

    private var emptyMessage: String {
        if model.isRefreshing, model.sessions.isEmpty {
            return "Scanning recent sessions…"
        }
        if !query.isEmpty {
            return "No sessions match “\(query)”."
        }
        return "No recent agent sessions\nin the last two weeks."
    }

    private func problemBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.08))
    }
}

private struct SessionRow: View {
    var item: SessionItem
    var isLaunching: Bool
    var isDisabled: Bool
    var onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                AgentBadge(agent: item.preview.provider, size: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayTitle)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                        Text(item.preview.projectName)
                            .lineLimit(1)
                        Text("\u{00B7}")
                        Text((item.mirrorOrigin ?? item.preview.provider).displayName)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Image(systemName: "diamond")
                        Text(item.preview.tokensLabel)
                        Text("\u{00B7}")
                        Image(systemName: "clock")
                        Text(Self.relativeTime.localizedString(for: item.preview.updatedAt, relativeTo: Date()))
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 10)

                if isLaunching {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .opacity(isHovering ? 1 : 0.35)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isHovering && !isDisabled ? AnyShapeStyle(.quaternary.opacity(0.7)) : AnyShapeStyle(.clear))
        )
        .onHover { hovering in
            isHovering = hovering
        }
        .help("Choose where to continue this conversation")
    }

    private static let relativeTime: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

private struct StatusBar: View {
    var status: AppStatus
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            switch status {
            case .idle:
                EmptyView()
            case .working(let text):
                // The launching row already shows a spinner; text is enough here.
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .notice(let text):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(text)
                    .font(.caption)
            case .error(let text):
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(text)
                    .font(.caption)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }

            Spacer()

            if case .working = status {
                EmptyView()
            } else {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
