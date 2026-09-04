import Foundation

/// Pure policy deciding whether a scanned QR payload is a UniConnect pairing link.
///
/// UniConnect pairing QR codes carry a `uniconnect://` deep link; any other QR content
/// (a website URL, a Wi-Fi join code) must be ignored so the scanner never
/// hands the connection layer a non-pairing string.
public struct MobilePairingScannerPolicy {
    private init() {}

    /// Whether `code` is a UniConnect pairing deep link the scanner should accept.
    /// - Parameter code: The raw string payload decoded from a QR code.
    /// - Returns: `true` only for `uniconnect://` pairing links.
    public static func acceptsCode(_ code: String) -> Bool {
        code.hasPrefix("uniconnect://")
    }
}
