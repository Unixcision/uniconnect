import Foundation

/// Inputs that determine one SSH endpoint without replacing its original destination alias.
struct UniConnectSSHTargetResolutionRequest: Equatable, Hashable, Sendable {
    let originalHost: String
    let explicitUser: String?
    let explicitHostName: String?
    let explicitPort: Int?
    let explicitCanonicalizeHostname: Bool?

    init(
        originalHost: String,
        explicitUser: String? = nil,
        explicitHostName: String? = nil,
        explicitPort: Int? = nil,
        explicitCanonicalizeHostname: Bool? = nil
    ) {
        self.originalHost = originalHost
        self.explicitUser = explicitUser
        self.explicitHostName = explicitHostName
        self.explicitPort = explicitPort
        self.explicitCanonicalizeHostname = explicitCanonicalizeHostname
    }
}
