import SwiftUI
import UniConnectClaudeUpdate

/// Modeless confirmation, progress, cancellation, and result UI for Claude updates.
struct UniConnectClaudeUpdateView: View {
    @Bindable var model: UniConnectClaudeUpdateModel
    let onConfirm: () -> Void
    let onCancel: () -> Void
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)
            content
            Divider().opacity(0.45)
            footer
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 440, idealHeight: 560)
        .background(background)
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.47, green: 0.33, blue: 0.98), Color(red: 0.16, green: 0.68, blue: 0.96)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)
            .shadow(color: Color.blue.opacity(0.22), radius: 12, y: 5)

            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "claudeUpdate.title", defaultValue: "Update Claude"))
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                Text(headerSubtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            if model.stage == .running {
                progressBadge
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private var content: some View {
        switch model.stage {
        case .preparing:
            centeredStatus(
                icon: "shield.lefthalf.filled",
                title: String(localized: "claudeUpdate.preparing.title", defaultValue: "Checking every session"),
                detail: String(
                    localized: "claudeUpdate.preparing.detail",
                    defaultValue: "UniConnect is resolving UUIDs, working folders, executables, hosts, and tmux panes before any input is sent."
                ),
                showsProgress: true
            )
        case .confirmation:
            confirmationContent
        case .running:
            runningContent
        case .completed:
            completedContent
        case .failed:
            centeredStatus(
                icon: "exclamationmark.shield.fill",
                title: String(localized: "claudeUpdate.failed.title", defaultValue: "Update not started"),
                detail: model.errorMessage ?? String(
                    localized: "claudeUpdate.error.preflight",
                    defaultValue: "UniConnect could not prepare a safe Claude update. No terminal input was sent."
                ),
                showsProgress: false
            )
        }
    }

    private var confirmationContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    metricBadge(
                        value: model.targetCount,
                        label: String(localized: "claudeUpdate.metric.windows", defaultValue: "windows"),
                        symbol: "macwindow.on.rectangle"
                    )
                    metricBadge(
                        value: model.hostCount,
                        label: String(localized: "claudeUpdate.metric.hosts", defaultValue: "hosts"),
                        symbol: "server.rack"
                    )
                    if model.unresolvedTargetCount > 0 {
                        metricBadge(
                            value: model.unresolvedTargetCount,
                            label: String(localized: "claudeUpdate.metric.skipped", defaultValue: "safe skips"),
                            symbol: "shield.slash"
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        String(localized: "claudeUpdate.confirm.safetyTitle", defaultValue: "What will happen"),
                        systemImage: "checkmark.shield.fill"
                    )
                    .font(.system(size: 13, weight: .semibold))
                    Text(String(
                        localized: "claudeUpdate.confirm.safetyDetail",
                        defaultValue: "Each verified Claude session exits cleanly, its host updates once, and the exact UUID resumes in the same window. Failed updates restore the previous session immediately."
                    ))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .background(cardBackground)

                if let plan = model.plan {
                    LazyVStack(spacing: 8) {
                        ForEach(plan.hosts) { hostPlan in
                            HostRow(
                                name: hostPlan.host.displayName,
                                kind: hostPlan.host.kind,
                                windowCount: hostPlan.targets.count,
                                isResolved: hostPlan.executablePath != nil
                            )
                        }
                    }
                }
            }
            .padding(22)
        }
    }

    private var runningContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(currentPhaseTitle)
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text(verbatim: "\(model.completedTargetCount)/\(model.targetCount)")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: model.completionFraction)
                        .progressViewStyle(.linear)
                        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: model.completionFraction)
                    if model.isCancellationRequested {
                        Label(
                            String(
                                localized: "claudeUpdate.cancelling.detail",
                                defaultValue: "Finishing required session restoration before stopping"
                            ),
                            systemImage: "arrow.uturn.backward.circle"
                        )
                        .font(.system(size: 11.5))
                        .foregroundStyle(.orange)
                    }
                }
                .padding(14)
                .background(cardBackground)

                if let plan = model.plan {
                    LazyVStack(spacing: 7) {
                        ForEach(plan.targets) { target in
                            let phase = model.progress?.targetPhases[target.id] ?? .pending
                            let outcome = model.progress?.outcomes.first { $0.targetID == target.id }
                            TargetRow(
                                name: target.displayName,
                                hostName: target.host.displayName,
                                phase: phase,
                                outcome: outcome,
                                stateLabel: outcome.map { localizedStatus($0.status) }
                                    ?? localizedPhase(phase)
                            )
                        }
                    }
                }
            }
            .padding(22)
        }
    }

    private var completedContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let summary = model.summary {
                    let successful = summary.outcomes.filter {
                        $0.status == .updated || $0.status == .alreadyUpdated
                    }.count
                    let restored = summary.outcomes.filter { $0.status == .restored }.count
                    let skipped = summary.outcomes.filter { $0.status == .skipped }.count
                    let failed = summary.outcomes.filter { $0.status == .failed }.count

                    HStack(spacing: 9) {
                        resultMetric(value: successful, label: localizedStatus(.updated), color: .green)
                        resultMetric(value: restored, label: localizedStatus(.restored), color: .blue)
                        resultMetric(value: skipped, label: localizedStatus(.skipped), color: .secondary)
                        resultMetric(value: failed, label: localizedStatus(.failed), color: .red)
                    }

                    LazyVStack(spacing: 8) {
                        ForEach(summary.hostOutcomes) { outcome in
                            ResultRow(
                                name: outcome.host.displayName,
                                status: localizedStatus(outcome.status),
                                detail: versionDetail(outcome),
                                symbol: statusSymbol(outcome.status),
                                color: statusColor(outcome.status)
                            )
                        }
                    }
                }
            }
            .padding(22)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            if model.stage == .running {
                Label(
                    String(localized: "claudeUpdate.footer.journal", defaultValue: "Recovery journal active"),
                    systemImage: "lock.shield"
                )
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
            Spacer()
            switch model.stage {
            case .preparing, .confirmation:
                Button(String(localized: "common.cancel", defaultValue: "Cancel"), action: onCancel)
                if model.stage == .confirmation {
                    Button(String(localized: "claudeUpdate.action.update", defaultValue: "Update Claude"), action: onConfirm)
                        .buttonStyle(.borderedProminent)
                }
            case .running:
                Button(
                    model.isCancellationRequested
                        ? String(localized: "claudeUpdate.action.cancelling", defaultValue: "Cancelling…")
                        : String(localized: "claudeUpdate.action.cancelSafely", defaultValue: "Cancel Safely"),
                    action: onCancel
                )
                .disabled(model.isCancellationRequested)
            case .completed, .failed:
                Button(String(localized: "common.close", defaultValue: "Close"), action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var background: some View {
        Rectangle()
            .fill(reduceTransparency ? Color(nsColor: .windowBackgroundColor) : Color.clear)
            .background(reduceTransparency ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.ultraThinMaterial))
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(reduceTransparency ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.thinMaterial))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.75)
            )
    }

    private var headerSubtitle: String {
        switch model.stage {
        case .preparing:
            return String(localized: "claudeUpdate.subtitle.preparing", defaultValue: "Safe preflight — nothing has been changed")
        case .confirmation:
            return String(localized: "claudeUpdate.subtitle.confirmation", defaultValue: "Review the exact update scope")
        case .running:
            return model.progress?.currentHost?.displayName
                ?? String(localized: "claudeUpdate.subtitle.running", defaultValue: "Updating and restoring sessions")
        case .completed:
            return String(localized: "claudeUpdate.subtitle.completed", defaultValue: "Every window has a final outcome")
        case .failed:
            return String(localized: "claudeUpdate.subtitle.failed", defaultValue: "Safety checks stopped the operation")
        }
    }

    private var currentPhaseTitle: String {
        guard let phase = model.progress?.phase else {
            return String(localized: "claudeUpdate.phase.preflight", defaultValue: "Running preflight")
        }
        return localizedPhase(phase)
    }

    private var progressBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(model.isCancellationRequested ? Color.orange : Color.green).frame(width: 7, height: 7)
            Text(model.isCancellationRequested
                ? String(localized: "claudeUpdate.badge.restoring", defaultValue: "RESTORING")
                : String(localized: "claudeUpdate.badge.live", defaultValue: "LIVE"))
                .font(.system(size: 10, weight: .bold, design: .rounded))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: Capsule())
    }

    private func centeredStatus(
        icon: String,
        title: String,
        detail: String,
        showsProgress: Bool
    ) -> some View {
        VStack(spacing: 13) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.tint)
            Text(title)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
            Text(detail)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if showsProgress { ProgressView().controlSize(.small) }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func metricBadge(value: Int, label: String, symbol: String) -> some View {
        Label {
            Text(verbatim: "\(value) \(label)")
        } icon: {
            Image(systemName: symbol)
        }
        .font(.system(size: 11.5, weight: .medium, design: .rounded))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.thinMaterial, in: Capsule())
    }

    private func resultMetric(value: Int, label: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(verbatim: "\(value)")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(label).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(cardBackground)
    }

    private func localizedPhase(_ phase: ClaudeUpdatePhase) -> String {
        switch phase {
        case .pending: return String(localized: "claudeUpdate.phase.pending", defaultValue: "Waiting")
        case .preflight: return String(localized: "claudeUpdate.phase.preflight", defaultValue: "Running preflight")
        case .waitingForIdle: return String(localized: "claudeUpdate.phase.waitingForIdle", defaultValue: "Waiting for Claude to finish")
        case .requestingExit: return String(localized: "claudeUpdate.phase.requestingExit", defaultValue: "Exiting cleanly")
        case .waitingForShell: return String(localized: "claudeUpdate.phase.waitingForShell", defaultValue: "Waiting for the shell")
        case .updating: return String(localized: "claudeUpdate.phase.updating", defaultValue: "Updating Claude")
        case .verifyingUpdate: return String(localized: "claudeUpdate.phase.verifyingUpdate", defaultValue: "Verifying the installed version")
        case .restoring: return String(localized: "claudeUpdate.phase.restoring", defaultValue: "Restoring sessions")
        case .verifyingSession: return String(localized: "claudeUpdate.phase.verifyingSession", defaultValue: "Verifying exact UUIDs")
        case .completed: return String(localized: "claudeUpdate.phase.completed", defaultValue: "Completed")
        }
    }

    private func localizedStatus(_ status: ClaudeUpdateOutcomeStatus) -> String {
        switch status {
        case .updated: return String(localized: "claudeUpdate.status.updated", defaultValue: "Updated")
        case .alreadyUpdated: return String(localized: "claudeUpdate.status.alreadyUpdated", defaultValue: "Current")
        case .restored: return String(localized: "claudeUpdate.status.restored", defaultValue: "Restored")
        case .skipped: return String(localized: "claudeUpdate.status.skipped", defaultValue: "Skipped")
        case .failed: return String(localized: "claudeUpdate.status.failed", defaultValue: "Failed")
        }
    }

    private func statusSymbol(_ status: ClaudeUpdateOutcomeStatus) -> String {
        switch status {
        case .updated: return "arrow.up.circle.fill"
        case .alreadyUpdated: return "checkmark.circle.fill"
        case .restored: return "arrow.uturn.backward.circle.fill"
        case .skipped: return "minus.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        }
    }

    private func statusColor(_ status: ClaudeUpdateOutcomeStatus) -> Color {
        switch status {
        case .updated, .alreadyUpdated: return .green
        case .restored: return .blue
        case .skipped: return .secondary
        case .failed: return .red
        }
    }

    private func versionDetail(_ outcome: ClaudeUpdateHostOutcome) -> String? {
        let version: String?
        switch (outcome.versionBefore, outcome.versionAfter) {
        case let (before?, after?): version = "\(before.description) → \(after.description)"
        case let (before?, nil): version = before.description
        case let (nil, after?): version = after.description
        case (nil, nil): version = nil
        }
        let issue = outcome.issue.map(localizedIssue)
        let detail = [version, issue].compactMap { $0 }.joined(separator: " · ")
        return detail.isEmpty ? nil : detail
    }

    private func localizedIssue(_ issue: ClaudeUpdateIssue) -> String {
        switch issue {
        case .missingSessionBinding:
            return String(localized: "claudeUpdate.issue.missingSessionBinding", defaultValue: "Session identity is incomplete")
        case .missingPaneIdentity:
            return String(localized: "claudeUpdate.issue.missingPaneIdentity", defaultValue: "tmux pane identity is incomplete")
        case .invalidTargetShape:
            return String(localized: "claudeUpdate.issue.invalidTargetShape", defaultValue: "Window identity is inconsistent")
        case .inspectionFailed:
            return String(localized: "claudeUpdate.issue.inspectionFailed", defaultValue: "The live session could not be inspected")
        case .processIdentityMismatch:
            return String(localized: "claudeUpdate.issue.processIdentityMismatch", defaultValue: "The running process no longer matches")
        case .idleTimeout:
            return String(localized: "claudeUpdate.issue.idleTimeout", defaultValue: "Claude did not become idle in time")
        case .journalUnavailable:
            return String(localized: "claudeUpdate.issue.journalUnavailable", defaultValue: "The recovery journal could not be secured")
        case .exitRequestFailed:
            return String(localized: "claudeUpdate.issue.exitRequestFailed", defaultValue: "Claude could not exit cleanly")
        case .shellTimeout:
            return String(localized: "claudeUpdate.issue.shellTimeout", defaultValue: "The original shell did not return")
        case .versionReadFailed:
            return String(localized: "claudeUpdate.issue.versionReadFailed", defaultValue: "The installed version could not be read")
        case .updateTimedOut:
            return String(localized: "claudeUpdate.issue.updateTimedOut", defaultValue: "The update timed out")
        case .updateCommandFailed:
            return String(localized: "claudeUpdate.issue.updateCommandFailed", defaultValue: "The update command failed")
        case .updateUnverifiable:
            return String(localized: "claudeUpdate.issue.updateUnverifiable", defaultValue: "The new version could not be verified")
        case .restorationFailed:
            return String(localized: "claudeUpdate.issue.restorationFailed", defaultValue: "The session could not be restored")
        case .restorationVerificationFailed:
            return String(localized: "claudeUpdate.issue.restorationVerificationFailed", defaultValue: "The restored UUID could not be verified")
        case .cancelled:
            return String(localized: "claudeUpdate.issue.cancelled", defaultValue: "Cancelled safely")
        }
    }

    private struct HostRow: View {
        let name: String
        let kind: ClaudeUpdateHostKind
        let windowCount: Int
        let isResolved: Bool

        var body: some View {
            HStack(spacing: 11) {
                Image(systemName: kind == .local ? "laptopcomputer" : "network")
                    .frame(width: 24)
                    .foregroundStyle(kind == .local ? Color.green : Color.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(String.localizedStringWithFormat(
                        String(
                            localized: "claudeUpdate.host.windowCount",
                            defaultValue: "%lld windows"
                        ),
                        Int64(windowCount)
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isResolved ? "checkmark.shield.fill" : "shield.slash.fill")
                    .foregroundStyle(isResolved ? Color.green : Color.secondary)
                    .accessibilityLabel(isResolved
                        ? String(localized: "claudeUpdate.accessibility.verified", defaultValue: "Verified")
                        : String(localized: "claudeUpdate.accessibility.skipped", defaultValue: "Will be skipped safely"))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
    }

    private struct TargetRow: View {
        let name: String
        let hostName: String
        let phase: ClaudeUpdatePhase
        let outcome: ClaudeUpdateOutcome?
        let stateLabel: String

        var body: some View {
            HStack(spacing: 11) {
                Image(systemName: outcome == nil ? "circle.dotted" : symbol)
                    .foregroundStyle(outcome == nil ? Color.accentColor : color)
                    .symbolEffect(.pulse, isActive: outcome == nil && phase != .pending)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Text(hostName).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(stateLabel)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }

        private var symbol: String {
            switch outcome?.status {
            case .updated, .alreadyUpdated: return "checkmark.circle.fill"
            case .restored: return "arrow.uturn.backward.circle.fill"
            case .skipped: return "minus.circle.fill"
            case .failed: return "exclamationmark.circle.fill"
            case nil: return "circle.dotted"
            }
        }

        private var color: Color {
            switch outcome?.status {
            case .updated, .alreadyUpdated: return .green
            case .restored: return .blue
            case .skipped: return .secondary
            case .failed: return .red
            case nil: return .accentColor
            }
        }
    }

    private struct ResultRow: View {
        let name: String
        let status: String
        let detail: String?
        let symbol: String
        let color: Color

        var body: some View {
            HStack(spacing: 11) {
                Image(systemName: symbol).foregroundStyle(color).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if let detail { Text(detail).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary) }
                }
                Spacer()
                Text(status).font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundStyle(color)
            }
            .padding(12)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
    }
}
