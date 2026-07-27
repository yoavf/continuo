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
        let initialTarget = item.primaryTarget
        _target = State(initialValue: initialTarget)
        _mode = State(
            initialValue: Self.originalTranscriptFits(item: item, target: initialTarget)
                ? .full
                : .handoff
        )
    }

    var body: some View {
        Group {
            if let prepared = model.preparedConversion, prepared.itemID == item.id {
                ConversionResultView(
                    model: model,
                    item: item,
                    prepared: prepared,
                    onDismiss: onDismiss
                )
            } else {
                configuration
            }
        }
        .frame(width: 480, alignment: .leading)
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

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
                        selectTarget(candidate)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Choose what to carry over")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                VStack(spacing: 7) {
                    CompactionModeCard(
                        mode: .full,
                        title: "Original transcript",
                        detail: originalTranscriptDetail,
                        status: originalFits ? "Fits" : "Doesn’t fit",
                        statusColor: originalFits ? .green : .orange,
                        isSelected: mode == .full,
                        isEnabled: originalFits
                    ) {
                        mode = .full
                    }
                    CompactionModeCard(
                        mode: .bookends,
                        title: "Beginning + latest work",
                        detail: "Keep the first 4 and latest 8 messages. Remove the middle and all tool calls and results.",
                        isSelected: mode == .bookends
                    ) {
                        mode = .bookends
                    }
                    CompactionModeCard(
                        mode: .handoff,
                        title: "Handoff summary",
                        detail: handoffDetail,
                        isSelected: mode == .handoff
                    ) {
                        mode = .handoff
                    }
                }
            }

            HStack {
                Button("Cancel") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    model.prepareResume(item, target: target, mode: mode)
                } label: {
                    HStack(spacing: 5) {
                        if model.launchingID == item.id {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "wand.and.stars")
                        }
                        Text(model.launchingID == item.id ? "Converting…" : "Convert & review")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(model.launchingID != nil)
            }
        }
        .padding(14)
    }

    private var header: some View {
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
    }

    /// Factual: which model this transfer would run under.
    private func detail(for candidate: AgentKind) -> String {
        "as \(Self.targetModel(item: item, target: candidate))"
    }

    private var selectedTargetModel: String {
        Self.targetModel(item: item, target: target)
    }

    private var originalFits: Bool {
        Self.originalTranscriptFits(item: item, target: target)
    }

    private var originalTranscriptDetail: String {
        if originalFits {
            return "Carry over all \(item.preview.tokensLabel), including messages and tool activity."
        }
        let limit = Self.compactTokens(
            transcriptTransferTokenLimit(forTargetModel: selectedTargetModel)
        )
        return "\(item.preview.tokensLabel) exceeds \(selectedTargetModel)’s ~\(limit) safe transfer limit."
    }

    private var handoffDetail: String {
        if Intelligence.isAvailable {
            return "On-device AI summarizes goals, decisions, files, current state, and next steps; keep the latest 8 messages."
        }
        return "Create a structured brief from the goal and recent focus; keep the latest 8 messages."
    }

    private func selectTarget(_ candidate: AgentKind) {
        target = candidate
        mode = Self.originalTranscriptFits(item: item, target: candidate) ? .full : .handoff
    }

    private static func originalTranscriptFits(item: SessionItem, target: AgentKind) -> Bool {
        fullTranscriptFits(
            estimatedTokens: item.preview.estimatedTokens,
            targetModel: targetModel(item: item, target: target)
        )
    }

    private static func targetModel(item: SessionItem, target: AgentKind) -> String {
        Prefs.configuration().resumeTargetModel(
            sourceModel: item.preview.models.first,
            sourceProvider: item.preview.provider,
            target: target
        )
    }

    private static func compactTokens(_ tokens: Int) -> String {
        switch tokens {
        case ..<1_000:
            return "\(tokens) tokens"
        case ..<1_000_000:
            return "\(tokens / 1_000)k tokens"
        default:
            return String(format: "%.1fM tokens", Double(tokens) / 1_000_000)
        }
    }
}

private struct CompactionModeCard: View {
    var mode: ResumeMode
    var title: String
    var detail: String
    var status: String? = nil
    var statusColor: Color = .accentColor
    var isSelected: Bool
    var isEnabled: Bool = true
    var onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                CompactionIllustration(mode: mode, isSelected: isSelected)
                    .frame(width: 74, height: 50)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.callout.weight(.semibold))
                        if let status {
                            Text(status)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(statusColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(statusColor.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: isEnabled ? (isSelected ? "largecircle.fill.circle" : "circle") : "xmark.circle.fill")
                    .foregroundStyle(
                        isEnabled
                            ? (isSelected ? Color.accentColor : Color.secondary)
                            : Color.secondary.opacity(0.55)
                    )
            }
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.10)) : AnyShapeStyle(.quaternary.opacity(0.28)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.65) : .clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .allowsHitTesting(isEnabled)
        .opacity(isEnabled ? 1 : 0.78)
        .accessibilityHint(isEnabled ? "" : detail)
    }
}

/// Tiny before/after diagrams make each mode understandable before reading its
/// description: stacked transcript turns on the left, resulting context on
/// the right.
private struct CompactionIllustration: View {
    var mode: ResumeMode
    var isSelected: Bool

    private var color: Color {
        isSelected ? .accentColor : .secondary
    }

    var body: some View {
        HStack(spacing: 5) {
            lineStack(count: 6, widths: [22, 17, 25, 19, 23, 15])
            Image(systemName: mode == .auto ? "sparkles" : "arrow.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color.opacity(0.8))
            switch mode {
            case .auto:
                VStack(spacing: 3) {
                    lineStack(count: 3, widths: [19, 14, 21])
                    Capsule()
                        .fill(color.opacity(0.35))
                        .frame(width: 17, height: 4)
                }
            case .full:
                lineStack(count: 6, widths: [22, 17, 25, 19, 23, 15])
            case .bookends:
                VStack(spacing: 3) {
                    lineStack(count: 2, widths: [19, 14])
                    HStack(spacing: 2) {
                        Circle().fill(color.opacity(0.3)).frame(width: 2, height: 2)
                        Circle().fill(color.opacity(0.3)).frame(width: 2, height: 2)
                        Circle().fill(color.opacity(0.3)).frame(width: 2, height: 2)
                    }
                    lineStack(count: 2, widths: [21, 16])
                }
            case .handoff:
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.22))
                        .frame(width: 25, height: 15)
                        .overlay(
                            Image(systemName: "text.alignleft")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(color)
                        )
                    lineStack(count: 2, widths: [20, 15])
                }
            }
        }
        .padding(7)
        .background(color.opacity(isSelected ? 0.09 : 0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func lineStack(count: Int, widths: [CGFloat]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(color.opacity(index.isMultiple(of: 2) ? 0.65 : 0.32))
                    .frame(width: widths[index % widths.count], height: 3)
            }
        }
    }
}

private struct ConversionResultView: View {
    @ObservedObject var model: AppModel
    var item: SessionItem
    var prepared: PreparedConversion
    var onDismiss: () -> Void

    private var ticket: ResumeTicket {
        prepared.ticket
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 11) {
                ZStack {
                    Circle()
                        .fill(.green.opacity(0.14))
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.green)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Conversion ready")
                        .font(.headline)
                    Text("Review what \(ticket.targetProvider.displayName) will receive before opening it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                ResultContextCard(
                    eyebrow: "ORIGINAL",
                    title: item.preview.tokensLabel,
                    detail: item.preview.provider.displayName,
                    agent: item.preview.provider
                )

                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)

                ResultContextCard(
                    eyebrow: ticket.effectiveMode == .full ? "TRANSFERRED" : "COMPACTED",
                    title: transferredTokensLabel,
                    detail: resultModeName,
                    agent: ticket.targetProvider
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(resultTitle)
                    .font(.callout.weight(.semibold))

                ForEach(resultDetails, id: \.self) { detail in
                    Label {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 8) {
                AgentBadge(agent: ticket.targetProvider, size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ticket.targetProvider.displayName)
                        .font(.caption.weight(.semibold))
                    Text(prepared.targetModel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(item.preview.projectName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Back to sessions") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Change options") {
                    model.clearPreparedConversion()
                }

                Spacer()

                Button {
                    model.launchPreparedConversion()
                } label: {
                    HStack(spacing: 6) {
                        if model.launchingID == item.id {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            AgentBadge(agent: ticket.targetProvider)
                        }
                        Text(model.launchingID == item.id ? "Opening…" : "Open in \(ticket.targetProvider.displayName)")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.launchingID != nil)
            }

            Text("The converted session is ready, but nothing has been opened yet.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(14)
    }

    private var resultModeName: String {
        switch ticket.effectiveMode {
        case .auto:
            return "Automatic"
        case .full:
            return "Original transcript"
        case .bookends:
            return "Beginning + latest"
        case .handoff:
            return "Handoff summary"
        }
    }

    private var resultTitle: String {
        switch ticket.effectiveMode {
        case .auto:
            return "The conversation was prepared"
        case .full:
            return "The original transcript was carried over"
        case .bookends:
            return "The beginning and latest work were kept"
        case .handoff:
            return "A focused handoff summary was created"
        }
    }

    private var resultDetails: [String] {
        switch ticket.effectiveMode {
        case .bookends:
            return [
                "The first 4 and latest 8 conversation messages are included.",
                "Middle conversation history and all tool calls and results were removed.",
                "The original \(item.preview.provider.displayName) session remains untouched."
            ]
        case .handoff:
            return [
                Intelligence.isAvailable
                    ? "An on-device summary covers goals, decisions, files, current state, and next steps."
                    : "A structured brief covers the original goal and recent focus.",
                "The latest 8 messages are included; tool calls and results were removed.",
                "The original \(item.preview.provider.displayName) session remains untouched."
            ]
        case .auto, .full:
            return [
                "Messages and portable tool activity were translated for \(ticket.targetProvider.displayName).",
                "No conversation events were removed.",
                "The original \(item.preview.provider.displayName) session remains untouched."
            ]
        }
    }

    private var transferredTokensLabel: String {
        // The engine's payload-bytes estimate measures what was actually
        // rendered; the preview's scanner heuristic would just duplicate the
        // ORIGINAL card.
        compactTokens(ticket.estimatedTransferredTokens)
    }

    private func compactTokens(_ tokens: Int) -> String {
        switch tokens {
        case ..<1_000:
            return tokens > 0 ? "~\(tokens) tokens" : "Ready"
        case ..<1_000_000:
            let value = Double(tokens) / 1_000
            return value < 10
                ? String(format: "~%.1fk tokens", value)
                : "~\(tokens / 1_000)k tokens"
        default:
            return String(format: "~%.1fM tokens", Double(tokens) / 1_000_000)
        }
    }
}

private struct ResultContextCard: View {
    var eyebrow: String
    var title: String
    var detail: String
    var agent: AgentKind

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            HStack(spacing: 5) {
                AgentBadge(agent: agent, size: 13)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 9))
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
