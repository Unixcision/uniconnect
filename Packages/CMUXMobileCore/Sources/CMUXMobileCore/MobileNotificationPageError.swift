/// A malformed request for a page of retained desktop notifications.
public enum MobileNotificationPageError: Error, Equatable, Sendable {
    /// The page size is not in the supported 1 through 200 range.
    case invalidLimit
    /// The opaque continuation cursor is malformed or unsupported.
    case invalidCursor
}
