import SwiftUI
import AppKit

// MARK: - Shared styling

enum UniConnectStyle {
    static let accent = Color(red: 0.95, green: 0.32, blue: 0.42)
    static let accentSSH = Color(red: 0.25, green: 0.72, blue: 0.95)
    static let paletteHex: [String] = {
        WorkspaceTabColorSettings.palette().map(\.hex)
    }()

    /// Terminal background from the user's Ghostty theme plus a matching foreground.
    static var terminalBackground: Color { Color(nsColor: GhosttyApp.shared.defaultBackgroundColor) }
    static var terminalBackgroundIsDark: Bool {
        let c = GhosttyApp.shared.defaultBackgroundColor.usingColorSpace(.sRGB) ?? .black
        let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return luminance < 0.5
    }
    /// Foreground that stays legible on `terminalBackground` (white on dark themes, near-black on light ones).
    static var onTerminal: Color { terminalBackgroundIsDark ? .white : Color(red: 0.10, green: 0.11, blue: 0.13) }

    static func color(hex: String) -> Color {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return .gray }
        return Color(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

struct UniConnectColorPicker: View {
    @Binding var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Color")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 8), count: 8), spacing: 8) {
                swatch(nil)
                ForEach(UniConnectStyle.paletteHex, id: \.self) { hex in
                    swatch(hex)
                }
            }
        }
    }

    private func swatch(_ hex: String?) -> some View {
        let isSelected = (selection ?? "").lowercased() == (hex ?? "").lowercased()
        return Button {
            selection = hex
        } label: {
            ZStack {
                if let hex {
                    Circle().fill(UniConnectStyle.color(hex: hex))
                } else {
                    Circle().strokeBorder(Color.secondary, lineWidth: 1)
                        .overlay(Image(systemName: "slash.circle").font(.system(size: 10)).foregroundStyle(.secondary))
                }
                if isSelected {
                    Circle().strokeBorder(Color.primary, lineWidth: 2).padding(-3)
                }
            }
            .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(hex ?? "Sin color")
    }
}

// MARK: - Sheet host

@MainActor
enum UniConnectSheet {
    private final class Host {
        var window: NSWindow?
        var parent: NSWindow?
    }

    /// Presents a SwiftUI view as a sheet on `parent` (or as a modal window when
    /// there is no parent). `dismiss` is handed to the content builder.
    static func present<Content: View>(
        on parent: NSWindow?,
        size: CGSize,
        @ViewBuilder content: (@escaping () -> Void) -> Content
    ) {
        let host = Host()
        let dismiss = {
            guard let window = host.window else { return }
            if let parent = host.parent {
                parent.endSheet(window)
            } else {
                NSApp.stopModal()
                window.orderOut(nil)
            }
            host.window = nil
        }
        let view = content(dismiss)
        let controller = NSHostingController(rootView: view.frame(width: size.width, height: size.height))
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.title = "UniConnect"
        host.window = window
        host.parent = parent
        if let parent {
            parent.beginSheet(window) { _ in }
        } else {
            window.center()
            NSApp.runModal(for: window)
        }
    }
}

// MARK: - New workspace (Local / SSH)

struct UniConnectNewWorkspaceView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case local, ssh
        var id: String { rawValue }
        var label: String { self == .local ? "Local" : "SSH" }
        var icon: String { self == .local ? "folder.fill" : "network" }
    }

    struct LocalResult {
        var name: String
        var folder: String
        var color: String?
    }

    struct SSHResult {
        var name: String
        var color: String?
        var connect: String
    }

    let onLocal: (LocalResult) -> Void
    let onSSH: (SSHResult) -> Void
    let onCancel: () -> Void

    @State private var kind: Kind = .local
    @State private var name = ""
    @State private var folder = ""
    @State private var connect = ""
    @State private var color: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "shippingbox.fill").foregroundStyle(UniConnectStyle.accent)
                Text("Nueva caja").font(.system(size: 20, weight: .bold, design: .rounded))
                Spacer()
            }
            Picker("", selection: $kind) {
                ForEach(Kind.allCases) { k in
                    Label(k.label, systemImage: k.icon).tag(k)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 10) {
                field("Nombre") {
                    TextField(kind == .local ? "NOTBETTING" : "VPS Hetzner", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                if kind == .local {
                    field("Carpeta") {
                        HStack {
                            TextField("~/Desktop/PROYECTOS/…", text: $folder)
                                .textFieldStyle(.roundedBorder)
                            Button("Elegir…") { chooseFolder() }
                        }
                    }
                } else {
                    field("Comando de conexión") {
                        TextField("sshpass -p 'clave' ssh root@1.2.3.4", text: $connect)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                    Text("Se guarda cifrado. Cada ventana de esta caja será una sesión tmux en el servidor; si no hay tmux, se instala.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                UniConnectColorPicker(selection: $color)
            }

            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancelar", action: onCancel).keyboardShortcut(.cancelAction)
                Button(kind == .local ? "Crear caja local" : "Conectar") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(kind == .local ? UniConnectStyle.accent : UniConnectStyle.accentSSH)
            }
        }
        .padding(20)
        .onChange(of: folder) { _, newValue in
            if name.isEmpty, !newValue.isEmpty {
                name = URL(fileURLWithPath: (newValue as NSString).expandingTildeInPath).lastPathComponent.uppercased()
            }
        }
    }

    private func field<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Elegir"
        if panel.runModal() == .OK, let url = panel.url {
            folder = url.path
        }
    }

    private func submit() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .local:
            let expanded = (folder.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard !expanded.isEmpty, FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
                error = "Elige una carpeta que exista."
                return
            }
            let resolvedName = trimmedName.isEmpty ? URL(fileURLWithPath: expanded).lastPathComponent.uppercased() : trimmedName
            onLocal(LocalResult(name: resolvedName, folder: expanded, color: color))
        case .ssh:
            let trimmedConnect = connect.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedConnect.isEmpty, trimmedConnect.contains("ssh") else {
                error = "Pega el comando completo de conexión (tiene que invocar ssh)."
                return
            }
            guard !trimmedConnect.contains("\n") else {
                error = "El comando no puede tener saltos de línea."
                return
            }
            let resolvedName = trimmedName.isEmpty ? UniConnectSSH.hostLabel(from: trimmedConnect) : trimmedName
            onSSH(SSHResult(name: resolvedName, color: color, connect: trimmedConnect))
        }
    }
}

// MARK: - New window in an SSH workspace

struct UniConnectNewWindowView: View {
    let workspaceName: String
    let onCreate: (_ name: String, _ tmux: String) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var tmux = ""
    @State private var tmuxEdited = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "macwindow.badge.plus").foregroundStyle(UniConnectStyle.accentSSH)
                Text("Nueva ventana en \(workspaceName)").font(.system(size: 18, weight: .bold, design: .rounded))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Nombre visible").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                TextField("claude, logs, deploy…", text: $name).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Código tmux (interno, para recuperar la sesión)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                TextField("uc-…", text: $tmux)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: tmux) { _, _ in tmuxEdited = true }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancelar", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Crear ventana") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(UniConnectStyle.accentSSH)
            }
        }
        .padding(20)
        .onChange(of: name) { _, newValue in
            guard !tmuxEdited || tmux.isEmpty else { return }
            tmux = newValue.isEmpty ? "" : UniConnectSSH.suggestedTmuxName(windowName: newValue)
            tmuxEdited = false
        }
    }

    private func submit() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { error = "Ponle un nombre a la ventana."; return }
        let candidate = tmux.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = UniConnectSSH.sanitizedTmuxName(candidate.isEmpty ? UniConnectSSH.suggestedTmuxName(windowName: trimmedName) : candidate)
        guard safe == candidate || candidate.isEmpty else {
            error = "El código tmux solo admite letras, números, guiones y guiones bajos. Sugerencia: \(safe)"
            tmux = safe
            tmuxEdited = true
            return
        }
        onCreate(trimmedName, safe)
    }
}

// MARK: - Full-page SSH welcome / setup

@MainActor
final class UniConnectSSHSetupState: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case needsInstall(String)
        case installing
        case ready
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var log: [String] = []
    let workspaceId: UUID

    init(workspaceId: UUID) {
        self.workspaceId = workspaceId
    }

    var isBusy: Bool {
        switch phase {
        case .connecting, .installing: return true
        default: return false
        }
    }
}

struct UniConnectSSHWelcomeView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var state: UniConnectSSHSetupState
    let onCreateWindow: (_ name: String, _ tmux: String) -> Void
    let onRetry: () -> Void
    let onEditConnection: () -> Void
    let onInstallTmux: () -> Void

    @State private var name = ""
    @State private var tmux = ""
    @State private var tmuxEdited = false
    @State private var error: String?

    private var title: String { workspace.customTitle ?? workspace.title }
    private var host: String { workspace.uniConnectProfile?.hostLabel ?? "servidor" }

    var body: some View {
        ZStack {
            // Follow the user's terminal theme (Ghostty background) so the page blends with
            // the app instead of introducing its own palette.
            UniConnectStyle.terminalBackground.ignoresSafeArea()
            UniConnectStyle.accentSSH.opacity(0.06).ignoresSafeArea()
            VStack(spacing: 26) {
                Spacer(minLength: 20)
                VStack(spacing: 8) {
                    Image(systemName: "network")
                        .font(.system(size: 54, weight: .thin))
                        .foregroundStyle(UniConnectStyle.accentSSH)
                    Text(title)
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(UniConnectStyle.onTerminal)
                    Text(host)
                        .font(.system(size: 18, weight: .medium, design: .monospaced))
                        .foregroundStyle(UniConnectStyle.onTerminal.opacity(0.6))
                }
                phaseView
                Spacer(minLength: 20)
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 40)
        }
    }

    @ViewBuilder
    private var phaseView: some View {
        switch state.phase {
        case .idle, .connecting, .installing:
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.regular).tint(UniConnectStyle.onTerminal)
                    Text(state.phase == .installing ? "Instalando tmux en el servidor…" : "Conectando y comprobando tmux…")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(UniConnectStyle.onTerminal)
                }
                logView
            }
        case .needsInstall(let detail):
            VStack(spacing: 14) {
                Text("tmux no está instalado en el servidor")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(UniConnectStyle.onTerminal)
                Text("Detectado: \(detail.replacingOccurrences(of: "=", with: ": ").replacingOccurrences(of: " ", with: " · "))")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(UniConnectStyle.onTerminal.opacity(0.7))
                    .multilineTextAlignment(.center)
                Text("UniConnect instalará el paquete tmux con el gestor del sistema (apt, dnf, yum, apk, pacman, zypper o brew). No toca nada más.")
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(UniConnectStyle.onTerminal.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                logView
                HStack(spacing: 12) {
                    Button { onInstallTmux() } label: { Label("Instalar tmux", systemImage: "arrow.down.circle.fill") }
                        .buttonStyle(.borderedProminent).tint(UniConnectStyle.accentSSH)
                        .disabled(detail.contains("SIN permisos"))
                    Button { onRetry() } label: { Label("Volver a comprobar", systemImage: "arrow.clockwise") }
                        .buttonStyle(.bordered)
                    Button { onEditConnection() } label: { Label("Editar conexión", systemImage: "pencil") }
                        .buttonStyle(.bordered)
                }
                if detail.contains("SIN permisos") {
                    Text("Este usuario no puede instalar paquetes (ni root ni sudo sin contraseña). Instala tmux a mano o conecta con otro usuario.")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(Color(red: 1, green: 0.7, blue: 0.5))
                        .multilineTextAlignment(.center)
                }
            }
        case .failed(let message):
            VStack(spacing: 14) {
                Text("No se pudo preparar el servidor")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 1, green: 0.55, blue: 0.55))
                Text(message)
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(UniConnectStyle.onTerminal.opacity(0.85))
                    .multilineTextAlignment(.center)
                logView
                HStack(spacing: 12) {
                    Button { onRetry() } label: { Label("Reintentar", systemImage: "arrow.clockwise") }
                        .buttonStyle(.borderedProminent).tint(UniConnectStyle.accentSSH)
                    Button { onEditConnection() } label: { Label("Editar conexión", systemImage: "pencil") }
                        .buttonStyle(.bordered)
                }
            }
        case .ready:
            VStack(spacing: 18) {
                Text("Servidor listo. Crea tu primera ventana.")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(UniConnectStyle.onTerminal)
                Text("Cada ventana es una sesión tmux con nombre en \(host). Si UniConnect se cierra o peta, la ventana sigue viva en el servidor y se reengancha sola al volver.")
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(UniConnectStyle.onTerminal.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Nombre de la ventana").font(.system(size: 13, weight: .semibold)).foregroundStyle(UniConnectStyle.onTerminal.opacity(0.7))
                    TextField("claude, logs, deploy…", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 18))
                        .onSubmit { submit() }
                    Text("Código tmux (interno, editable)").font(.system(size: 13, weight: .semibold)).foregroundStyle(UniConnectStyle.onTerminal.opacity(0.7))
                    TextField("uc-…", text: $tmux)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 15, design: .monospaced))
                        .onChange(of: tmux) { _, _ in tmuxEdited = true }
                    if let error { Text(error).font(.system(size: 13)).foregroundStyle(Color(red: 1, green: 0.55, blue: 0.55)) }
                    HStack {
                        Spacer()
                        Button { submit() } label: {
                            Label("Crear ventana", systemImage: "plus")
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 14).padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(UniConnectStyle.accentSSH)
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(20)
                .background(RoundedRectangle(cornerRadius: 14).fill(UniConnectStyle.onTerminal.opacity(0.06)))
                .frame(maxWidth: 560)
                .onChange(of: name) { _, newValue in
                    guard !tmuxEdited || tmux.isEmpty else { return }
                    tmux = newValue.isEmpty ? "" : UniConnectSSH.suggestedTmuxName(windowName: newValue)
                    tmuxEdited = false
                }
            }
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(state.log.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(UniConnectStyle.onTerminal.opacity(0.75))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(12)
            }
            .frame(maxWidth: 680, minHeight: 80, maxHeight: 220)
            .background(RoundedRectangle(cornerRadius: 10).fill(UniConnectStyle.onTerminal.opacity(0.08)))
            .onChange(of: state.log.count) { _, count in
                if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
    }

    private func submit() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { error = "Ponle un nombre a la ventana."; return }
        let candidate = tmux.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = UniConnectSSH.sanitizedTmuxName(candidate.isEmpty ? UniConnectSSH.suggestedTmuxName(windowName: trimmedName) : candidate)
        guard candidate.isEmpty || safe == candidate else {
            error = "El código tmux solo admite letras, números, guiones y guiones bajos. Sugerencia: \(safe)"
            tmux = safe
            tmuxEdited = true
            return
        }
        error = nil
        onCreateWindow(trimmedName, safe)
    }
}

// MARK: - Passphrase prompt (export / import)

struct UniConnectPassphraseView: View {
    let title: String
    let message: String
    let confirm: Bool
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var passphrase = ""
    @State private var repeatPassphrase = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "lock.shield.fill").foregroundStyle(UniConnectStyle.accent)
                Text(title).font(.system(size: 18, weight: .bold, design: .rounded))
            }
            Text(message).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("Contraseña", text: $passphrase).textFieldStyle(.roundedBorder)
            if confirm {
                SecureField("Repite la contraseña", text: $repeatPassphrase).textFieldStyle(.roundedBorder)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancelar", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Continuar") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(UniConnectStyle.accent)
            }
        }
        .padding(20)
    }

    private func submit() {
        guard passphrase.count >= (confirm ? 8 : 1) else {
            error = confirm ? "Mínimo 8 caracteres." : "Escribe la contraseña."
            return
        }
        if confirm, passphrase != repeatPassphrase {
            error = "Las contraseñas no coinciden."
            return
        }
        onSubmit(passphrase)
    }
}

// MARK: - Import preview

struct UniConnectImportPreviewView: View {
    struct Row: Identifiable {
        let id = UUID()
        let workspace: UniConnectDocument.Workspace
        let existsAlready: Bool
    }

    let rows: [Row]
    let onImport: (_ selected: [UniConnectDocument.Workspace]) -> Void
    let onCancel: () -> Void

    @State private var selected: Set<UUID> = []

    init(rows: [Row], onImport: @escaping ([UniConnectDocument.Workspace]) -> Void, onCancel: @escaping () -> Void) {
        self.rows = rows
        self.onImport = onImport
        self.onCancel = onCancel
        _selected = State(initialValue: Set(rows.filter { !$0.existsAlready }.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "square.and.arrow.down.fill").foregroundStyle(UniConnectStyle.accent)
                Text("Importar configuración").font(.system(size: 18, weight: .bold, design: .rounded))
            }
            Text("Marca las cajas que quieres crear. Las que ya existen con el mismo nombre vienen desmarcadas para no duplicarlas.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List(rows) { row in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(
                        get: { selected.contains(row.id) },
                        set: { on in if on { selected.insert(row.id) } else { selected.remove(row.id) } }
                    )).labelsHidden()
                    Circle().fill(row.workspace.color.map { UniConnectStyle.color(hex: $0) } ?? .gray).frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(row.workspace.name).font(.system(size: 13, weight: .semibold))
                            Text(row.workspace.kind == .ssh ? "SSH" : "Local")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(row.workspace.kind == .ssh ? UniConnectStyle.accentSSH.opacity(0.25) : Color.secondary.opacity(0.2)))
                            if row.existsAlready {
                                Text("ya existe").font(.system(size: 10)).foregroundStyle(.orange)
                            }
                        }
                        Text(row.workspace.kind == .ssh
                             ? "\(UniConnectSSH.hostLabel(from: row.workspace.connect ?? "")) · \(row.workspace.windows.count) ventanas tmux"
                             : "\(row.workspace.cwd ?? "~") · \(row.workspace.windows.count) ventanas")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
            }
            HStack {
                Button("Todas") { selected = Set(rows.map(\.id)) }
                Button("Ninguna") { selected = [] }
                Spacer()
                Button("Cancelar", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Importar \(selected.count)") {
                    onImport(rows.filter { selected.contains($0.id) }.map(\.workspace))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(UniConnectStyle.accent)
                .disabled(selected.isEmpty)
            }
        }
        .padding(20)
    }
}
