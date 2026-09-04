import Foundation

/// Source metadata kept separately from the persisted UniConnect document.
struct UniConnectImportSourceMap: Equatable, Sendable {
    struct WindowKey: Equatable, Hashable, Sendable {
        let workspaceIndex: Int
        let windowIndex: Int
    }

    var workspaceLocations: [Int: UniConnectImportSourceLocation] = [:]
    var windowLocations: [WindowKey: UniConnectImportSourceLocation] = [:]
    var tmuxPolicies: [WindowKey: UniConnectTmuxImportPolicy] = [:]
    var diagnosticsByWorkspace: [Int: [UniConnectImportDiagnostic]] = [:]
    var diagnosticsByWindow: [WindowKey: [UniConnectImportDiagnostic]] = [:]
    var documentDiagnostics: [UniConnectImportDiagnostic] = []

    static let empty = UniConnectImportSourceMap()
}
