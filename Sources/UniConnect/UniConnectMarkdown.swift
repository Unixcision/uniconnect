import Foundation

/// Parses the human-authored `CONNECT.md` format without executing any declaration.
enum UniConnectMarkdown {
    /// Cheap check used before parsing so an unrelated text file is not treated as CONNECT.
    static func looksLikeConnectionMap(_ text: String) -> Bool {
        let lowered = normalized(text)
        guard lowered.contains("#") else { return false }
        return lowered.contains("tmux")
            || lowered.contains("ssh ")
            || lowered.contains("sshpass ")
            || lowered.contains("--resume")
    }

    /// Parses a connection map while preserving source locations and invalid declarations.
    static func parseDetailed(_ text: String) throws -> UniConnectMarkdownParseResult {
        let lines = text.components(separatedBy: .newlines)
        var accumulated: [BuiltBox] = []
        var current: Box?
        var fence: Fence?
        var sectionKind: UniConnectWorkspaceKind?

        func finishCurrent() {
            guard let current else { return }
            accumulated.append(current.build())
        }

        for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if var openFence = fence {
                if line.hasPrefix("```") {
                    current?.absorb(codeBlock: openFence.lines)
                    fence = nil
                } else {
                    openFence.lines.append(SourceLine(number: lineNumber, text: rawLine))
                    fence = openFence
                }
                continue
            }

            if line.hasPrefix("```") {
                fence = Fence(openingLine: lineNumber, lines: [])
                continue
            }

            if let heading = heading(in: line, line: lineNumber) {
                if heading.level <= 2 {
                    finishCurrent()
                    current = nil
                    sectionKind = Self.sectionKind(from: heading.rawTitle)
                } else {
                    finishCurrent()
                    current = nil
                    if let name = workspaceName(from: heading.rawTitle) {
                        current = Box(
                            name: name,
                            location: .init(line: lineNumber, section: name),
                            declaredKind: explicitKind(from: heading.rawTitle) ?? sectionKind,
                            defaultTmuxPolicy: tmuxPolicy(from: heading.rawTitle)
                        )
                    } else {
                        let invalid = Box(
                            name: "",
                            location: .init(line: lineNumber, section: nil),
                            declaredKind: explicitKind(from: heading.rawTitle) ?? sectionKind,
                            defaultTmuxPolicy: tmuxPolicy(from: heading.rawTitle)
                        )
                        invalid.diagnostics.append(.init(
                            severity: .error,
                            code: .workspaceMissingName,
                            location: .init(line: lineNumber, section: nil),
                            subject: nil
                        ))
                        current = invalid
                    }
                }
                continue
            }

            guard let current else { continue }
            if line.hasPrefix("|") {
                current.absorb(tableRow: line, lineNumber: lineNumber)
                continue
            }
            current.absorb(narrativeLine: line, lineNumber: lineNumber)
        }

        if let openFence = fence {
            current?.absorb(codeBlock: openFence.lines)
            current?.diagnostics.append(.init(
                severity: .error,
                code: .unclosedCodeFence,
                location: .init(line: openFence.openingLine, section: current?.name),
                subject: current?.name
            ))
        }
        finishCurrent()

        let recognised = accumulated.filter { box in
            !box.workspace.windows.isEmpty || box.workspace.connect != nil || !box.diagnostics.isEmpty
        }
        guard !recognised.isEmpty else {
            throw UniConnectError.corruptFile(String(
                localized: "uniconnect.markdown.error.noRecognizableBox",
                defaultValue: "the Markdown does not contain any recognizable box"
            ))
        }

        var sourceMap = UniConnectImportSourceMap()
        for (workspaceIndex, box) in recognised.enumerated() {
            sourceMap.workspaceLocations[workspaceIndex] = box.location
            if !box.diagnostics.isEmpty {
                sourceMap.diagnosticsByWorkspace[workspaceIndex] = box.diagnostics
            }
            for (windowIndex, declaration) in box.windows.enumerated() {
                let key = UniConnectImportSourceMap.WindowKey(
                    workspaceIndex: workspaceIndex,
                    windowIndex: windowIndex
                )
                sourceMap.windowLocations[key] = declaration.location
                sourceMap.tmuxPolicies[key] = declaration.tmuxPolicy
                if !declaration.diagnostics.isEmpty {
                    sourceMap.diagnosticsByWindow[key] = declaration.diagnostics
                }
            }
        }

        return UniConnectMarkdownParseResult(
            document: UniConnectDocument(workspaces: recognised.map(\.workspace)),
            sourceMap: sourceMap
        )
    }

    static func parse(_ text: String) throws -> UniConnectDocument {
        try parseDetailed(text).document
    }

    private struct SourceLine {
        let number: Int
        let text: String
    }

    private struct Fence {
        let openingLine: Int
        var lines: [SourceLine]
    }

    private struct Heading {
        let level: Int
        let rawTitle: String
    }

    private struct WindowDeclaration {
        var window: UniConnectDocument.Window
        let location: UniConnectImportSourceLocation
        var tmuxPolicy: UniConnectTmuxImportPolicy
        var diagnostics: [UniConnectImportDiagnostic]
        let cameFromTable: Bool
    }

    private struct BuiltBox {
        let workspace: UniConnectDocument.Workspace
        let location: UniConnectImportSourceLocation
        let windows: [WindowDeclaration]
        let diagnostics: [UniConnectImportDiagnostic]
    }

    private final class Box {
        let name: String
        let location: UniConnectImportSourceLocation
        private let declaredKind: UniConnectWorkspaceKind?
        private var observedKind: UniConnectWorkspaceKind?
        private var defaultTmuxPolicy: UniConnectTmuxImportPolicy
        private var connect: String?
        private var cwd: String?
        private var windows: [WindowDeclaration] = []
        fileprivate var diagnostics: [UniConnectImportDiagnostic] = []
        private var headerColumns: [Column] = []
        private var tableTmuxPolicy: UniConnectTmuxImportPolicy?

        init(
            name: String,
            location: UniConnectImportSourceLocation,
            declaredKind: UniConnectWorkspaceKind?,
            defaultTmuxPolicy: UniConnectTmuxImportPolicy
        ) {
            self.name = name
            self.location = location
            self.declaredKind = declaredKind
            self.defaultTmuxPolicy = defaultTmuxPolicy
        }

        func absorb(narrativeLine line: String, lineNumber: Int) {
            guard !line.isEmpty else { return }
            let policy = UniConnectMarkdown.tmuxPolicy(from: line)
            if policy != .unspecified { defaultTmuxPolicy = policy }

            let folded = UniConnectMarkdown.normalized(line)
            if folded.contains("tmux"), line.contains("`") {
                absorb(inlineTmuxLine: line, lineNumber: lineNumber, policy: policy)
            }
        }

        func absorb(tableRow line: String, lineNumber: Int) {
            let rawCells = line
                .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                .components(separatedBy: "|")
            let cells = rawCells.map(UniConnectMarkdown.cleanMarkdownCell)
            guard cells.count >= 2 else {
                appendWorkspaceDiagnostic(.malformedTableRow, at: lineNumber)
                return
            }
            if cells.allSatisfy({ cell in
                !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" }
            }) {
                return
            }

            let columns = cells.map(Column.init)
            if columns.contains(where: \.isRecognisedHeader) {
                headerColumns = columns
                tableTmuxPolicy = columns.compactMap(\.declaredTmuxPolicy).first
                return
            }
            guard !headerColumns.isEmpty else {
                appendWorkspaceDiagnostic(.malformedTableRow, at: lineNumber)
                return
            }

            var name: String?
            var tmux: String?
            var session: String?
            var directory: String?
            for (index, cell) in cells.enumerated() where index < headerColumns.count {
                guard !cell.isEmpty else { continue }
                switch headerColumns[index].kind {
                case .name:
                    name = cell
                case .tmux:
                    tmux = cell
                case .session:
                    session = cell
                case .directory:
                    directory = UniConnectMarkdown.expandPath(cell)
                case .ignored:
                    continue
                }
            }

            if name == nil, let tmux { name = tmux }
            let lineLocation = UniConnectImportSourceLocation(line: lineNumber, section: self.name)
            var rowDiagnostics: [UniConnectImportDiagnostic] = []
            if tmux == nil, session == nil {
                rowDiagnostics.append(.init(
                    severity: .error,
                    code: .windowMissingIdentity,
                    location: lineLocation,
                    subject: name
                ))
            }
            windows.append(WindowDeclaration(
                window: .init(
                    name: name,
                    tmux: tmux,
                    claudeSession: session,
                    cwd: directory,
                    isPinned: nil
                ),
                location: lineLocation,
                tmuxPolicy: tableTmuxPolicy ?? defaultTmuxPolicy,
                diagnostics: rowDiagnostics,
                cameFromTable: true
            ))
        }

        func absorb(codeBlock lines: [SourceLine]) {
            for sourceLine in lines {
                let line = sourceLine.text.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#") else { continue }

                if connect == nil, looksLikePotentialSSHCommand(line) {
                    connect = line
                    observe(kind: .ssh, lineNumber: sourceLine.number)
                    continue
                }

                if line.contains("--resume") {
                    guard let session = claudeSession(in: line) else {
                        appendWorkspaceDiagnostic(.malformedClaudeResume, at: sourceLine.number)
                        continue
                    }
                    let directory = workingDirectory(in: line)
                    let label = trailingComment(in: line)
                    mergeOrAppendClaude(
                        session: session,
                        directory: directory,
                        label: label,
                        lineNumber: sourceLine.number
                    )
                    continue
                }

                if UniConnectMarkdown.normalized(line).contains("tmux") {
                    absorb(tmuxCommandLine: line, lineNumber: sourceLine.number)
                }
            }
        }

        func build() -> BuiltBox {
            let kind = observedKind ?? declaredKind ?? .local
            if let declaredKind, let observedKind, declaredKind != observedKind {
                appendWorkspaceDiagnostic(.conflictingWorkspaceKind, at: location.line)
            }
            let folder = cwd ?? windows.compactMap(\.window.cwd).first
            return BuiltBox(
                workspace: .init(
                    name: name,
                    kind: kind,
                    color: nil,
                    group: nil,
                    isPinned: nil,
                    cwd: folder,
                    connect: connect,
                    windows: windows.map(\.window)
                ),
                location: location,
                windows: windows,
                diagnostics: diagnostics
            )
        }

        private func absorb(
            inlineTmuxLine line: String,
            lineNumber: Int,
            policy: UniConnectTmuxImportPolicy
        ) {
            let ticks = line.components(separatedBy: "`")
            guard ticks.count >= 3 else {
                appendWorkspaceDiagnostic(.malformedTmuxDeclaration, at: lineNumber)
                return
            }
            let session = UniConnectMarkdown.cleanMarkdownCell(ticks[1])
            guard !session.isEmpty, !session.contains(where: \.isWhitespace) else {
                appendWorkspaceDiagnostic(.malformedTmuxDeclaration, at: lineNumber)
                return
            }
            var windowName = session
            if let range = line.range(of: #"\*\*([^*]{1,120})\*\*\s*$"#, options: .regularExpression) {
                windowName = line[range]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " *"))
            }
            mergeOrAppendTmux(
                session: session,
                name: windowName,
                lineNumber: lineNumber,
                policy: policy == .unspecified ? defaultTmuxPolicy : policy
            )
        }

        private func absorb(tmuxCommandLine line: String, lineNumber: Int) {
            for segment in line.components(separatedBy: ";") {
                let words = UniConnectSSH.shellWords(segment)
                guard let tmuxIndex = words.firstIndex(where: { ($0 as NSString).lastPathComponent == "tmux" }) else {
                    continue
                }
                let arguments = Array(words.dropFirst(tmuxIndex + 1))
                let foldedArguments = arguments.map(UniConnectMarkdown.normalized)
                let policy: UniConnectTmuxImportPolicy
                if foldedArguments.contains("attach") || foldedArguments.contains("attach-session") {
                    policy = .attachExisting
                } else if foldedArguments.contains("new") || foldedArguments.contains("new-session") {
                    policy = .createIfMissing
                } else {
                    continue
                }
                guard let session = value(afterAnyOf: ["-t", "-s"], in: arguments), !session.isEmpty else {
                    appendWorkspaceDiagnostic(.malformedTmuxDeclaration, at: lineNumber)
                    continue
                }
                mergeOrAppendTmux(
                    session: session,
                    name: session,
                    lineNumber: lineNumber,
                    policy: policy
                )
            }
        }

        private func mergeOrAppendClaude(
            session: String,
            directory: String?,
            label: String?,
            lineNumber: Int
        ) {
            let matchingTableIndexes = windows.indices.filter {
                windows[$0].cameFromTable
                    && windows[$0].window.claudeSession?.caseInsensitiveCompare(session) == .orderedSame
            }
            if !matchingTableIndexes.isEmpty {
                for index in matchingTableIndexes where windows[index].window.cwd == nil {
                    windows[index].window.cwd = directory
                }
                if cwd == nil { cwd = directory }
                return
            }

            let lineLocation = UniConnectImportSourceLocation(line: lineNumber, section: name)
            windows.append(WindowDeclaration(
                window: .init(
                    name: label,
                    tmux: nil,
                    claudeSession: session,
                    cwd: directory,
                    isPinned: nil
                ),
                location: lineLocation,
                tmuxPolicy: .unspecified,
                diagnostics: [],
                cameFromTable: false
            ))
            if cwd == nil { cwd = directory }
        }

        private func mergeOrAppendTmux(
            session: String,
            name: String,
            lineNumber: Int,
            policy: UniConnectTmuxImportPolicy
        ) {
            if let index = windows.firstIndex(where: { $0.window.tmux == session }) {
                if windows[index].tmuxPolicy == .unspecified {
                    windows[index].tmuxPolicy = policy
                }
                return
            }
            let lineLocation = UniConnectImportSourceLocation(line: lineNumber, section: self.name)
            windows.append(WindowDeclaration(
                window: .init(
                    name: name,
                    tmux: session,
                    claudeSession: nil,
                    cwd: nil,
                    isPinned: nil
                ),
                location: lineLocation,
                tmuxPolicy: policy,
                diagnostics: [],
                cameFromTable: false
            ))
        }

        private func observe(kind: UniConnectWorkspaceKind, lineNumber: Int) {
            if let observedKind, observedKind != kind {
                appendWorkspaceDiagnostic(.conflictingWorkspaceKind, at: lineNumber)
            }
            observedKind = kind
        }

        private func appendWorkspaceDiagnostic(
            _ code: UniConnectImportDiagnostic.Code,
            at lineNumber: Int
        ) {
            let diagnostic = UniConnectImportDiagnostic(
                severity: .error,
                code: code,
                location: .init(line: lineNumber, section: name),
                subject: name
            )
            if !diagnostics.contains(diagnostic) { diagnostics.append(diagnostic) }
        }

        private func claudeSession(in line: String) -> String? {
            let words = UniConnectSSH.shellWords(line)
            for (index, word) in words.enumerated() {
                if word == "--resume", words.indices.contains(index + 1) {
                    return words[index + 1]
                }
                if word.hasPrefix("--resume=") {
                    return String(word.dropFirst("--resume=".count))
                }
            }
            return nil
        }

        private func looksLikePotentialSSHCommand(_ line: String) -> Bool {
            line.range(
                of: #"^(?:\S*/)?(?:sshpass|ssh)(?:\s|$|[;&|<>()`$])"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        }

        private func workingDirectory(in line: String) -> String? {
            guard let range = line.range(
                of: #"(?:^|[;&]\s*)cd\s+(\"[^\"]+\"|'[^']+'|[^\s&;]+)"#,
                options: .regularExpression
            ) else { return nil }
            var path = String(line[range])
            guard let cdRange = path.range(of: #"cd\s+"#, options: .regularExpression) else { return nil }
            path.removeSubrange(path.startIndex..<cdRange.upperBound)
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return UniConnectMarkdown.expandPath(path)
        }

        private func trailingComment(in line: String) -> String? {
            guard let hash = line.range(of: "#", options: .backwards) else { return nil }
            let text = line[hash.upperBound...].trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }

        private func value(afterAnyOf options: Set<String>, in words: [String]) -> String? {
            for (index, word) in words.enumerated() where options.contains(word) {
                guard words.indices.contains(index + 1) else { return nil }
                return words[index + 1]
            }
            return nil
        }
    }

    private struct Column {
        enum Kind: Equatable {
            case name
            case tmux
            case session
            case directory
            case ignored
        }

        let text: String
        let kind: Kind

        init(_ text: String) {
            self.text = UniConnectMarkdown.normalized(text)
            if self.text == "ventana" || self.text == "window" || self.text == "nombre" {
                kind = .name
            } else if self.text.contains("tmux") {
                kind = .tmux
            } else if self.text.contains("uuid")
                || self.text.contains("sesion")
                || self.text.contains("session") {
                kind = .session
            } else if self.text.contains("ruta") || self.text == "cwd" || self.text.contains("carpeta") {
                kind = .directory
            } else {
                kind = .ignored
            }
        }

        var isRecognisedHeader: Bool {
            switch kind {
            case .ignored: false
            default: true
            }
        }

        var declaredTmuxPolicy: UniConnectTmuxImportPolicy? {
            guard kind == .tmux else { return nil }
            let policy = UniConnectMarkdown.tmuxPolicy(from: text)
            return policy == .unspecified ? nil : policy
        }
    }

    private static func heading(in line: String, line _: Int) -> Heading? {
        guard line.hasPrefix("#") else { return nil }
        let level = line.prefix(while: { $0 == "#" }).count
        guard level > 0 else { return nil }
        let title = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
        return Heading(level: level, rawTitle: title)
    }

    private static func workspaceName(from rawTitle: String) -> String? {
        if let quoted = rawTitle.range(
            of: #"(?:Caja|Box)\s+[\"“]([^\"”]+)[\"”]"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            let matched = String(rawTitle[quoted])
            if let firstQuote = matched.firstIndex(where: { $0 == "\"" || $0 == "“" }),
               let lastQuote = matched.lastIndex(where: { $0 == "\"" || $0 == "”" }),
               firstQuote < lastQuote {
                let name = matched[matched.index(after: firstQuote)..<lastQuote]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? nil : name
            }
        }

        var title = rawTitle
        if let range = title.range(
            of: #"^[0-9]+(?:\.[0-9]+)*\s*[·.\-–—]?\s*"#,
            options: .regularExpression
        ) {
            title.removeSubrange(range)
        }
        title = title.replacingOccurrences(
            of: #"^(?:Caja|Box)\s+"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        for separator in [" — ", " – ", " -- "] {
            if let range = title.range(of: separator) {
                title = String(title[..<range.lowerBound])
                break
            }
        }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " \"'`*"))
        return title.isEmpty ? nil : title
    }

    private static func sectionKind(from title: String) -> UniConnectWorkspaceKind? {
        let value = normalized(title)
        if value.contains("cajas locales") || value.contains("local workspaces") { return .local }
        if value.contains("cajas ssh") || value.contains("ssh workspaces") { return .ssh }
        return nil
    }

    private static func explicitKind(from text: String) -> UniConnectWorkspaceKind? {
        let value = normalized(text)
        if value.range(of: #"(?:^|\s)ssh(?:\s|$)"#, options: .regularExpression) != nil { return .ssh }
        if value.range(of: #"(?:^|\s)local(?:\s|$)"#, options: .regularExpression) != nil { return .local }
        return nil
    }

    private static func tmuxPolicy(from text: String) -> UniConnectTmuxImportPolicy {
        let value = normalized(text)
        if value.contains("existente")
            || value.contains("already exists")
            || value.contains("no crear")
            || value.contains("do not create") {
            return .attachExisting
        }
        if value.contains("a crear")
            || value.contains("crear uno")
            || value.contains("create if missing")
            || value.contains("create these") {
            return .createIfMissing
        }
        return .unspecified
    }

    private static func cleanMarkdownCell(_ value: String) -> String {
        var cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " `*"))
        if let warning = cleaned.firstIndex(of: "⚠") {
            cleaned = String(cleaned[..<warning]).trimmingCharacters(in: .whitespaces)
        }
        return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " `*"))
    }

    private static func expandPath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}
