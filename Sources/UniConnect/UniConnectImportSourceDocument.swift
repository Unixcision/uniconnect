import Foundation

/// A parsed JSON or Markdown import plus non-secret source metadata.
struct UniConnectImportSourceDocument: Equatable {
    let document: UniConnectDocument
    let sourceMap: UniConnectImportSourceMap
}
