import Foundation

/// An in-memory import payload plus source diagnostics and optional encrypted-backup records.
struct UniConnectImportSourceDocument: Equatable {
    let document: UniConnectDocument
    let sourceMap: UniConnectImportSourceMap
    /// Complete records recovered from an encrypted companion, keyed by source row.
    ///
    /// Plain JSON/Markdown imports leave this empty. The transaction resolves those
    /// declarations exactly once before preflight and keeps the resulting record in
    /// memory; readable backups retain the endpoint captured when they were written.
    let sshCredentialRecordsByWorkspaceIndex: [Int: UniConnectSSHCredentialRecord]

    init(
        document: UniConnectDocument,
        sourceMap: UniConnectImportSourceMap,
        sshCredentialRecordsByWorkspaceIndex: [Int: UniConnectSSHCredentialRecord] = [:]
    ) {
        self.document = document
        self.sourceMap = sourceMap
        self.sshCredentialRecordsByWorkspaceIndex = sshCredentialRecordsByWorkspaceIndex
    }
}
