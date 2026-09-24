import Foundation
import Testing

/// Reads the shared contract files of the repository (`contracts/…`) from a test.
///
/// It walks up from the test's own file until it finds a folder that contains `contracts/`, so it
/// does not depend on how deep the package sits in the repository. When the folder or a file is
/// missing the test **fails** (`#require`): a contract test that passes without comparing anything
/// is worse than no test (D8, 24-09-2026).
struct ContractFixtures {
    /// The `contracts/` folder, or `nil` when no ancestor of the test file has one.
    let root: URL?

    /// Locates `contracts/` from a test file.
    ///
    /// - Parameter testFile: The caller's `#filePath`.
    init(testFile: String = #filePath) {
        root = Self.locate(from: testFile)
    }

    /// The bytes of one contract file.
    ///
    /// - Parameter relativePath: A path inside `contracts/`, such as `agent-tree-v1/sonda-salida.json`.
    /// - Returns: The file's contents.
    /// - Throws: When `contracts/` or the file cannot be found; the missing file is recorded as an issue.
    func data(_ relativePath: String) throws -> Data {
        let folder = try #require(root, "No se encuentra contracts/ subiendo desde el test")
        let url = folder.appendingPathComponent(relativePath)
        return try #require(try? Data(contentsOf: url), "Falta contracts/\(relativePath)")
    }

    /// One contract file decoded as a JSON object.
    ///
    /// - Parameter relativePath: A path inside `contracts/`.
    /// - Returns: The top-level object.
    /// - Throws: When the file is missing or is not a JSON object.
    func object(_ relativePath: String) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: data(relativePath))
        return try #require(value as? [String: Any], "contracts/\(relativePath) no es un objeto JSON")
    }

    /// Walks the path components instead of `deletingLastPathComponent()`, which on macOS 14 and
    /// 15 turns `/` into `/..` and would never stop.
    private static func locate(from testFile: String) -> URL? {
        var components = URL(fileURLWithPath: testFile).deletingLastPathComponent().pathComponents
        while !components.isEmpty {
            let candidate = NSString.path(withComponents: components + ["contracts"])
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return URL(fileURLWithPath: candidate, isDirectory: true)
            }
            components.removeLast()
        }
        return nil
    }
}
