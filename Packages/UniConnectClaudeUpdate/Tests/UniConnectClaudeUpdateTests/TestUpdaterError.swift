/// Deterministic failures injected by ``TestUpdaterHarness``.
enum TestUpdaterError: Error {
    case updateFailed
    case restoreFailed
    case invalidProcess
}
