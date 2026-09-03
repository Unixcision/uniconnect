import Foundation

/// Reads a hand-written Markdown map of boxes and windows (the `CONNECT.md` shape) and
/// turns it into the same document the JSON seed produces.
///
/// The format is deliberately forgiving because it is written by a person, not a tool:
///
/// ```markdown
/// ### 2.2 · Caja "TipsterTrusts" — 1 ventana
///
/// | Ventana | UUID | Ruta |
/// |---------|------|------|
/// | TIPSTERTRUST | bd3a3ea6-… | ~/Desktop/PROYECTOS/TIPSTERTRUST |
///
/// ### 3.4 · NOTBETTING — 6 tmux EXISTENTES
///
/// ```bash
/// ssh -i ~/keys.pem root@1.2.3.4
/// ```
///
/// | # | tmux |
/// | 1 | claudefixerrors |
/// ```
///
/// Rules: a heading opens a box; a fenced block whose first word is `ssh` or `sshpass`
/// makes it an SSH box with that connect command; tables provide the windows (a `tmux`
/// column for SSH boxes, a UUID column for local ones).
enum UniConnectMarkdown {
    /// Cheap check used before parsing so a stray text file is not mistaken for a map.
    static func looksLikeConnectionMap(_ text: String) -> Bool {
        let lowered = text.lowercased()
        guard lowered.contains("#") else { return false }
        return lowered.contains("tmux") || lowered.contains("ssh ") || lowered.contains("--resume")
    }

    static func parse(_ text: String) throws -> UniConnectDocument {
        var boxes: [UniConnectDocument.Workspace] = []
        var current: Box?
        var fence: Fence?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                if fence == nil {
                    fence = Fence(lines: [])
                } else {
                    if let body = fence?.lines { current?.absorb(codeBlock: body) }
                    fence = nil
                }
                continue
            }
            if fence != nil {
                fence?.lines.append(rawLine)
                continue
            }

            if let title = headingTitle(line) {
                if let box = current?.build() { boxes.append(box) }
                current = title.isEmpty ? nil : Box(name: title)
                continue
            }

            if line.hasPrefix("|") {
                current?.absorb(tableRow: line)
                continue
            }

            // "**tmux existente:** `claudemtproto` → nombrar la ventana **SUPPORT**"
            if line.lowercased().contains("tmux"), line.contains("`") {
                current?.absorb(inlineTmuxLine: line)
            }
        }
        if let box = current?.build() { boxes.append(box) }

        let deduped = dedupe(boxes)
        guard !deduped.isEmpty else {
            throw UniConnectError.corruptFile("el Markdown no contiene ninguna caja reconocible")
        }
        return UniConnectDocument(workspaces: deduped)
    }

    // MARK: Heading

    /// Accepts `## Caja "X"`, `### 3.4 · NOTBETTING — 6 tmux`, `## 1. Resumen`, …
    /// Returns nil for lines that are not headings, and "" for headings that open no box.
    private static func headingTitle(_ line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        var title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        // Drop the numbering prefix ("3.4 ·", "2.", "1 -").
        if let range = title.range(of: #"^[0-9]+(\.[0-9]+)*\s*[·.\-–—]?\s*"#, options: .regularExpression) {
            title.removeSubrange(range)
        }
        // Drop trailing descriptions after an em dash: "NOTBETTING — 6 tmux EXISTENTES".
        for separator in [" — ", " – ", " -- "] {
            if let range = title.range(of: separator) { title = String(title[..<range.lowerBound]) }
        }
        title = title.replacingOccurrences(of: "^(Caja|Box)\\s+", with: "", options: [.regularExpression, .caseInsensitive])
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " \"'`*"))
        // Section headings that describe the document rather than a box.
        let skip = ["convenciones globales", "resumen de cajas", "cajas locales", "cajas ssh",
                    "avisos y cosas a decidir", "avisos", "índice", "indice"]
        if skip.contains(where: { title.lowercased().contains($0) }) { return "" }
        return title
    }

    private static func dedupe(_ boxes: [UniConnectDocument.Workspace]) -> [UniConnectDocument.Workspace] {
        var seen: Set<String> = []
        var result: [UniConnectDocument.Workspace] = []
        for box in boxes where !box.windows.isEmpty || box.connect != nil {
            let key = box.name.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(box)
        }
        return result
    }

    // MARK: Accumulator

    private struct Fence {
        var lines: [String]
    }

    private final class Box {
        let name: String
        var connect: String?
        var cwd: String?
        var windows: [UniConnectDocument.Window] = []
        private var headerColumns: [String] = []

        init(name: String) { self.name = name }

        /// A fenced block: the first line that starts with ssh/sshpass is the connection.
        /// Lines with `claude --resume <uuid>` describe local windows.
        func absorb(codeBlock lines: [String]) {
            for raw in lines {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#") else { continue }
                if connect == nil, UniConnectSSH.validateConnectCommand(line) == nil {
                    connect = line
                    continue
                }
                if let session = claudeSession(in: line) {
                    let directory = workingDirectory(in: line)
                    let label = comment(in: line)
                    if !windows.contains(where: { $0.claudeSession == session }) {
                        windows.append(UniConnectDocument.Window(
                            name: label,
                            tmux: nil,
                            claudeSession: session,
                            cwd: directory,
                            isPinned: nil
                        ))
                    } else if let label, let index = windows.firstIndex(where: { $0.claudeSession == session && ($0.name ?? "").isEmpty }) {
                        windows[index].name = label
                    }
                }
            }
        }

        func absorb(tableRow line: String) {
            let cells = line
                .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                .components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " `*")) }
            guard cells.count >= 2 else { return }
            // Separator row: |---|---|
            if cells.allSatisfy({ $0.allSatisfy { $0 == "-" || $0 == ":" } && !$0.isEmpty }) { return }
            let lowered = cells.map { $0.lowercased() }
            if lowered.contains(where: { ["ventana", "window", "tmux", "uuid", "ruta", "sesión", "sesion", "#"].contains($0) }) {
                headerColumns = lowered
                return
            }
            guard !headerColumns.isEmpty else { return }
            var name: String?
            var tmux: String?
            var session: String?
            var directory: String?
            for (index, cell) in cells.enumerated() where index < headerColumns.count {
                let column = headerColumns[index]
                if cell.isEmpty { continue }
                switch column {
                case "ventana", "window":
                    name = cell
                case "tmux":
                    tmux = cell
                case "uuid", "sesión", "sesion":
                    session = uuid(in: cell)
                case "ruta", "cwd", "carpeta", "ruta de arranque":
                    directory = expand(cell)
                default:
                    if column.contains("ruta") { directory = expand(cell) }
                }
            }
            if name == nil, tmux != nil { name = tmux }
            if tmux == nil, session == nil { return }
            if let tmux, windows.contains(where: { $0.tmux == tmux }) { return }
            if let session, windows.contains(where: { $0.claudeSession == session }) { return }
            windows.append(UniConnectDocument.Window(
                name: name,
                tmux: tmux,
                claudeSession: session,
                cwd: directory,
                isPinned: nil
            ))
        }

        /// "**tmux existente:** `claudemtproto` → nombrar la ventana **SUPPORT**"
        func absorb(inlineTmuxLine line: String) {
            let ticks = line.components(separatedBy: "`")
            guard ticks.count >= 3 else { return }
            let session = ticks[1].trimmingCharacters(in: .whitespaces)
            guard !session.isEmpty, !session.contains(" "), !windows.contains(where: { $0.tmux == session }) else { return }
            var name = session
            if let range = line.range(of: #"\*\*([A-Z0-9_\-]{2,})\*\*\s*$"#, options: .regularExpression) {
                name = line[range].trimmingCharacters(in: CharacterSet(charactersIn: " *"))
            }
            windows.append(UniConnectDocument.Window(name: name, tmux: session, claudeSession: nil, cwd: nil, isPinned: nil))
        }

        func build() -> UniConnectDocument.Workspace? {
            guard !name.isEmpty else { return nil }
            let kind: UniConnectWorkspaceKind = connect == nil ? .local : .ssh
            if kind == .local {
                guard windows.contains(where: { $0.claudeSession != nil }) else { return nil }
            }
            let folder = cwd ?? windows.compactMap(\.cwd).first
            return UniConnectDocument.Workspace(
                name: name,
                kind: kind,
                color: nil,
                group: nil,
                isPinned: nil,
                cwd: folder,
                connect: connect,
                windows: windows
            )
        }

        private func claudeSession(in line: String) -> String? {
            guard line.contains("--resume") else { return nil }
            return uuid(in: line)
        }

        private func uuid(in text: String) -> String? {
            let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
            guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
            return String(text[range])
        }

        private func workingDirectory(in line: String) -> String? {
            guard let range = line.range(of: #"cd\s+("[^"]+"|'[^']+'|[^\s&;]+)"#, options: .regularExpression) else { return nil }
            var path = String(line[range]).replacingOccurrences(of: "cd", with: "").trimmingCharacters(in: .whitespaces)
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return expand(path)
        }

        /// Trailing `# APP 1` comment used as the window name.
        private func comment(in line: String) -> String? {
            guard let hash = line.range(of: "#", options: .backwards) else { return nil }
            let text = line[hash.upperBound...].trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }

        private func expand(_ path: String) -> String {
            (path as NSString).expandingTildeInPath
        }
    }
}
