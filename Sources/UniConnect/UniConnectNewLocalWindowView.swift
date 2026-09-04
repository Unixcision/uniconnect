import SwiftUI

/// Modern local-window chooser for a terminal, built-in agent, or configured custom agent.
struct UniConnectNewLocalWindowView: View {
    private enum Selection: String, CaseIterable, Identifiable {
        case terminal
        case claude
        case codex
        case agy
        case grok
        case custom

        var id: String { rawValue }
    }

    private static let manualCustomID = "__uniconnect_manual_agent__"

    let workspaceName: String
    let boxRoot: String
    let availableCustomTargets: [UniConnectLocalWindowLaunchTarget]
    let onCreate: (UniConnectNewLocalWindowRequest) -> Void
    let onCancel: () -> Void

    @State private var selection: Selection = .terminal
    @State private var visibleName = ""
    @State private var selectedCustomTargetID: String
    @State private var customName = ""
    @State private var customExecutable = ""
    @State private var errorMessage: String?

    init(
        workspaceName: String,
        boxRoot: String,
        availableCustomTargets: [UniConnectLocalWindowLaunchTarget] = [],
        onCreate: @escaping (UniConnectNewLocalWindowRequest) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.workspaceName = workspaceName
        self.boxRoot = boxRoot
        self.availableCustomTargets = availableCustomTargets
        self.onCreate = onCreate
        self.onCancel = onCancel
        _selectedCustomTargetID = State(
            initialValue: availableCustomTargets.first?.id ?? Self.manualCustomID
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            trustedRootCard

            Text(
                String(
                    localized: "uniconnect.localWindow.new.chooseType",
                    defaultValue: "What should this window open?"
                )
            )
            .font(.system(size: 13, weight: .semibold, design: .rounded))

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                spacing: 10
            ) {
                ForEach(Selection.allCases) { item in
                    targetCard(item)
                }
            }

            if selection == .custom {
                customAgentFields
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(
                    String(
                        localized: "uniconnect.localWindow.new.name",
                        defaultValue: "Window Name"
                    )
                )
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                TextField(defaultWindowName, text: $visibleName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("UniConnectLocalWindowNameField")
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .animation(.snappy(duration: 0.22), value: selection)
        .accessibilityIdentifier("UniConnectNewLocalWindow")
    }

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.68)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "macwindow.badge.plus")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(
                    String(
                        localized: "uniconnect.localWindow.new.title",
                        defaultValue: "New Window"
                    )
                )
                .font(.system(size: 19, weight: .bold, design: .rounded))
                Text(workspaceName)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var trustedRootCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    String(
                        localized: "uniconnect.localWindow.new.trustedRoot",
                        defaultValue: "Trusted Box Folder"
                    )
                )
                .font(.system(size: 10.5, weight: .semibold))
                Text(boxRoot)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Text(
                String(
                    localized: "uniconnect.localWindow.new.always",
                    defaultValue: "ALWAYS"
                )
            )
            .font(.system(size: 8.5, weight: .bold, design: .rounded))
            .foregroundStyle(.green)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.green.opacity(0.12), in: Capsule())
        }
        .padding(10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.7)
        }
    }

    private func targetCard(_ item: Selection) -> some View {
        let selected = selection == item
        let presentation = presentation(for: item)
        return Button {
            selection = item
            errorMessage = nil
        } label: {
            HStack(spacing: 9) {
                targetIcon(item)
                    .frame(width: 27, height: 27)

                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.name)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text(presentation.summary)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.45))
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 57, alignment: .leading)
            .background(
                selected ? Color.accentColor.opacity(0.11) : Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(
                        selected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08),
                        lineWidth: selected ? 1.2 : 0.7
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(presentation.name)
        .accessibilityValue(selected ? String(localized: "settings.state.selected", defaultValue: "Selected") : "")
        .accessibilityIdentifier("UniConnectLocalWindowTarget-\(item.rawValue)")
    }

    @ViewBuilder
    private func targetIcon(_ item: Selection) -> some View {
        if let target = builtInTarget(for: item),
           let assetName = target.iconAssetName {
            Image(assetName)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(systemName: builtInTarget(for: item)?.systemImageName ?? "person.crop.circle.badge.gearshape")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(item == .terminal ? Color.secondary : Color.accentColor)
        }
    }

    private var customAgentFields: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !availableCustomTargets.isEmpty {
                field(
                    String(
                        localized: "uniconnect.localWindow.new.configuredAgent",
                        defaultValue: "Configured Agent"
                    )
                ) {
                    Picker("", selection: $selectedCustomTargetID) {
                        ForEach(availableCustomTargets) { target in
                            Text(target.displayName).tag(target.id)
                        }
                        Text(
                            String(
                                localized: "uniconnect.localWindow.new.otherExecutable",
                                defaultValue: "Other Executable…"
                            )
                        )
                        .tag(Self.manualCustomID)
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
            }

            if availableCustomTargets.isEmpty || selectedCustomTargetID == Self.manualCustomID {
                HStack(alignment: .top, spacing: 10) {
                    field(
                        String(
                            localized: "uniconnect.localWindow.new.agentName",
                            defaultValue: "Agent Name"
                        )
                    ) {
                        TextField(
                            String(
                                localized: "uniconnect.localWindow.new.agentName.placeholder",
                                defaultValue: "My Agent"
                            ),
                            text: $customName
                        )
                        .textFieldStyle(.roundedBorder)
                    }
                    field(
                        String(
                            localized: "uniconnect.localWindow.new.executable",
                            defaultValue: "Executable"
                        )
                    ) {
                        TextField(
                            String(
                                localized: "uniconnect.localWindow.new.executable.placeholder",
                                defaultValue: "agent-cli"
                            ),
                            text: $customExecutable
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    }
                }
            }
        }
        .padding(11)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var footer: some View {
        HStack {
            Text(
                String(
                    localized: "uniconnect.localWindow.new.exitHint",
                    defaultValue: "After /exit, the agent returns to this window's shell."
                )
            )
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 10)
            Button(
                String(localized: "common.cancel", defaultValue: "Cancel"),
                action: onCancel
            )
            .keyboardShortcut(.cancelAction)
            Button(
                String(localized: "uniconnect.localWindow.new.create", defaultValue: "Create Window")
            ) {
                submit()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
    }

    private func field<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var defaultWindowName: String {
        resolvedTarget?.displayName
            ?? String(localized: "uniconnect.localWindow.target.custom", defaultValue: "Custom Agent")
    }

    private var resolvedTarget: UniConnectLocalWindowLaunchTarget? {
        if let builtIn = builtInTarget(for: selection) { return builtIn }
        if let configured = availableCustomTargets.first(where: { $0.id == selectedCustomTargetID }) {
            return configured
        }
        let name = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        let executable = customExecutable.trimmingCharacters(in: .whitespacesAndNewlines)
        return UniConnectLocalWindowLaunchTarget.custom(
            id: customIdentifier(name: name, executable: executable),
            name: name,
            executable: executable
        )
    }

    private func builtInTarget(
        for item: Selection
    ) -> UniConnectLocalWindowLaunchTarget? {
        switch item {
        case .terminal: return .terminal
        case .claude: return .claude
        case .codex: return .codex
        case .agy: return .agy
        case .grok: return .grok
        case .custom: return nil
        }
    }

    private func presentation(
        for item: Selection
    ) -> (name: String, summary: String) {
        if let target = builtInTarget(for: item) {
            return (target.displayName, target.localizedSummary)
        }
        return (
            String(localized: "uniconnect.localWindow.target.custom", defaultValue: "Custom Agent"),
            String(
                localized: "uniconnect.localWindow.target.custom.summary",
                defaultValue: "A configured CLI agent in this box's trusted folder."
            )
        )
    }

    private func customIdentifier(name: String, executable: String) -> String {
        let source = name.isEmpty ? executable : name
        let components = source.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let collapsed = String(components)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "custom-agent" : String(collapsed.prefix(64))
    }

    private func submit() {
        guard let target = resolvedTarget else {
            errorMessage = String(
                localized: "uniconnect.localWindow.new.error.invalidCustomAgent",
                defaultValue: "Enter a name and executable for the custom agent."
            )
            return
        }
        guard let request = UniConnectNewLocalWindowRequest(
            visibleName: visibleName,
            boxRoot: boxRoot,
            launchTarget: target
        ) else {
            errorMessage = String(
                localized: "uniconnect.localWindow.new.error.missingRoot",
                defaultValue: "This box does not have a trusted folder."
            )
            return
        }
        onCreate(request)
    }
}
