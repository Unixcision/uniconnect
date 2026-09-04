import Foundation

/// Identifies a declaration in a human-authored import without retaining its raw text.
struct UniConnectImportSourceLocation: Equatable, Hashable, Sendable {
    let line: Int
    let section: String?

    init(line: Int, section: String? = nil) {
        self.line = max(1, line)
        self.section = section?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
