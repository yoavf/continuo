import AgentSyncCore
import SwiftUI

/// Second page of the popover: pick where (and with how much context) to
/// continue the selected conversation.
struct ContinueView: View {
    @ObservedObject var model: AppModel
    var item: SessionItem
    var onDismiss: () -> Void

    @State private var target: AgentKind
    @State private var mode: ResumeMode

    init(model: AppModel, item: SessionItem, onDismiss: @escaping () -> Void) {
        self.model = model
        self.item = item
        self.onDismiss = onDismiss
        _target = State(initialValue: item.primaryTarget)
        _mode = State(initialValue: Prefs.transferMode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back")

                VStack(alignment: .leading, spacing: 2) {
                    Text("Continue “\(item.displayTitle)”")
                        .font(.headline)
                        .lineLimit(2)
                    Text("\(item.preview.projectName) · \(item.preview.tokensLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Continue in")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(item.targets, id: \.self) { candidate in
                    TargetCard(
                        agent: candidate,
                        detail: detail(for: candidate),
                        isSelected: candidate == target
                    ) {
                        target = candidate
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Carry over")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("", selection: $mode) {
                    Text("Auto — full when it fits, brief otherwise").tag(ResumeMode.auto)
                    Text("Full conversation (trimmed if needed)").tag(ResumeMode.full)
                    Text("Handoff brief — summary + recent turns").tag(ResumeMode.handoff)
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            HStack {
                Button("Cancel") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    model.resume(item, target: target, mode: mode)
                    onDismiss()
                } label: {
                    HStack(spacing: 5) {
                        AgentBadge(agent: target)
                        Text("Continue in \(target.displayName)")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(width: 480, alignment: .leading)
    }

    /// Factual: which model this transfer would run under.
    private func detail(for candidate: AgentKind) -> String {
        switch candidate {
        case .opencode:
            let configured = Prefs.opencodeResumeModel
            return configured.isEmpty ? "OpenCode's own model choice" : "as \(configured)"
        default:
            let mapped = Prefs.modelMappings().targetModel(
                forSourceModel: item.preview.models.first,
                sourceProvider: item.preview.provider,
                targetProvider: candidate
            )
            return "as \(mapped)"
        }
    }
}

private struct TargetCard: View {
    var agent: AgentKind
    var detail: String
    var isSelected: Bool
    var onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                AgentBadge(agent: agent, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.displayName)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.35)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }
}

/// Shared small app-icon badge.
struct AgentBadge: View {
    var agent: AgentKind
    var size: CGFloat = 16

    var body: some View {
        if let icon = agent.appIcon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size + 3, height: size + 3)
        } else {
            Image(systemName: agent.symbolName)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(agent.tint)
                .frame(width: size, height: size)
                .background(agent.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
        }
    }
}
