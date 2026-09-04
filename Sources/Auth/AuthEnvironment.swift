import Foundation

enum AuthEnvironment {
    // Keep unconfigured builds structurally valid without ever falling back to
    // cmux's Stack Auth tenants. Real deployments inject their own values.
    private static let unconfiguredStackProjectID = "00000000-0000-4000-8000-000000000000"
    private static let unconfiguredStackPublishableClientKey = "unconfigured-uniconnect-publishable-key"

    /// A complete, explicitly enabled configuration for UniConnect-hosted services.
    ///
    /// Keeping this as a single value prevents auth, Cloud VM, push, and mobile
    /// pairing from independently guessing whether a partial deployment is usable.
    /// The app constructs those services only when this value resolves.
    struct HostedServicesConfiguration: Equatable, Sendable {
        let stackProjectID: String
        let stackPublishableClientKey: String
        let stackBaseURL: URL
        let authWebsiteOrigin: URL
        let apiBaseURL: URL
        let vmAPIBaseURL: URL
    }

    /// The hosted-services configuration for this process, or `nil` when the
    /// feature is disabled or any required endpoint/credential is missing.
    static var hostedServices: HostedServicesConfiguration? {
        hostedServicesConfiguration(
            environment: ProcessInfo.processInfo.environment,
            infoDictionary: Bundle.main.infoDictionary ?? [:],
            allowsInsecureLoopback: allowsInsecureLoopbackHostedServices
        )
    }

    /// Resolves the all-or-nothing hosted-services policy from explicit inputs.
    ///
    /// `UNICONNECT_HOSTED_SERVICES_ENABLED=1` (or the matching Info.plist flag)
    /// is mandatory. Release builds additionally require HTTPS. Debug builds may
    /// opt into loopback HTTP for local UI tests, but never accept arbitrary
    /// plaintext remote endpoints. Partial configuration always fails closed.
    static func hostedServicesConfiguration(
        environment: [String: String],
        infoDictionary: [String: Any],
        allowsInsecureLoopback: Bool
    ) -> HostedServicesConfiguration? {
        guard explicitlyEnabled(
            environment["UNICONNECT_HOSTED_SERVICES_ENABLED"]
                ?? stringValue(infoDictionary["UniConnectHostedServicesEnabled"])
        ) else {
            return nil
        }

        guard let projectID = configuredString(
            environment: environment,
            environmentKey: "CMUX_STACK_PROJECT_ID",
            infoDictionary: infoDictionary,
            infoKey: "UniConnectStackProjectID"
        ), UUID(uuidString: projectID) != nil,
              projectID.lowercased() != unconfiguredStackProjectID,
              let clientKey = configuredString(
                  environment: environment,
                  environmentKey: "CMUX_STACK_PUBLISHABLE_CLIENT_KEY",
                  infoDictionary: infoDictionary,
                  infoKey: "UniConnectStackPublishableClientKey"
              ), clientKey != unconfiguredStackPublishableClientKey,
              !clientKey.lowercased().contains("unconfigured"),
              let authWebsiteOrigin = configuredHostedURL(
                  environment: environment,
                  environmentKey: "CMUX_AUTH_WWW_ORIGIN",
                  infoDictionary: infoDictionary,
                  infoKey: "UniConnectAuthWebsiteOrigin",
                  allowsInsecureLoopback: allowsInsecureLoopback
              ),
              let apiBaseURL = configuredHostedURL(
                  environment: environment,
                  environmentKey: "CMUX_API_BASE_URL",
                  infoDictionary: infoDictionary,
                  infoKey: "UniConnectAPIBaseURL",
                  allowsInsecureLoopback: allowsInsecureLoopback
              ),
              let vmAPIBaseURL = configuredHostedURL(
                  environment: environment,
                  environmentKey: "CMUX_VM_API_BASE_URL",
                  infoDictionary: infoDictionary,
                  infoKey: "UniConnectVMAPIBaseURL",
                  allowsInsecureLoopback: allowsInsecureLoopback
              ) else {
            return nil
        }

        let stackBaseURL: URL
        if let configuredStackURL = configuredString(
            environment: environment,
            environmentKey: "CMUX_STACK_BASE_URL",
            infoDictionary: infoDictionary,
            infoKey: "UniConnectStackBaseURL"
        ) {
            guard let resolved = validatedServiceURL(
                configuredStackURL,
                allowsInsecureLoopback: allowsInsecureLoopback,
                rejectsNonOwnedProductHosts: false
            ) else {
                return nil
            }
            stackBaseURL = resolved
        } else {
            stackBaseURL = URL(string: "https://api.stack-auth.com")!
        }

        return HostedServicesConfiguration(
            stackProjectID: projectID,
            stackPublishableClientKey: clientKey,
            stackBaseURL: stackBaseURL,
            authWebsiteOrigin: authWebsiteOrigin,
            apiBaseURL: apiBaseURL,
            vmAPIBaseURL: vmAPIBaseURL
        )
    }

    private static var allowsInsecureLoopbackHostedServices: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    static var callbackScheme: String {
        let environment = ProcessInfo.processInfo.environment
        if let overridden = environment["CMUX_AUTH_CALLBACK_SCHEME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !overridden.isEmpty {
            return overridden
        }
        #if DEBUG
        // Debug and tagged dev builds register uniconnect-dev:// so they can coexist
        // with the installed stable app.
        return "uniconnect-dev"
        #else
        if Bundle.main.bundleIdentifier == "com.unixcision.uniconnect.nightly" {
            return "uniconnect-nightly"
        }
        return "uniconnect"
        #endif
    }

    static var callbackURL: URL {
        URL(string: "\(callbackScheme)://auth-callback")!
    }

    static func signInURL(afterSignInOrigin: URL) -> URL {
        // Build the after-sign-in callback URL that includes the native app return scheme.
        // The after-sign-in handler extracts tokens from the Stack Auth session
        // and redirects to the native app via the uniconnect:// callback scheme.
        var afterSignInComponents = URLComponents(
            url: afterSignInOrigin.appendingPathComponent("handler/after-sign-in", isDirectory: false),
            resolvingAgainstBaseURL: false
        )!
        afterSignInComponents.queryItems = [
            URLQueryItem(
                name: "native_app_return_to",
                value: callbackURL.absoluteString
            ),
        ]

        // Use the website's /sign-in route (provided by Stack Auth SDK).
        // Stack Auth handles the sign-in flow, then redirects to after_auth_return_to.
        var components = URLComponents(
            url: afterSignInOrigin.appendingPathComponent("handler/sign-in", isDirectory: false),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(
                name: "after_auth_return_to",
                value: afterSignInComponents.url!.absoluteString
            ),
        ]
        return components.url!
    }

    private static func configuredString(
        environment: [String: String],
        environmentKey: String,
        infoDictionary: [String: Any],
        infoKey: String
    ) -> String? {
        let raw = environment[environmentKey] ?? stringValue(infoDictionary[infoKey])
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func configuredHostedURL(
        environment: [String: String],
        environmentKey: String,
        infoDictionary: [String: Any],
        infoKey: String,
        allowsInsecureLoopback: Bool
    ) -> URL? {
        guard let raw = configuredString(
            environment: environment,
            environmentKey: environmentKey,
            infoDictionary: infoDictionary,
            infoKey: infoKey
        ) else {
            return nil
        }
        return validatedServiceURL(
            raw,
            allowsInsecureLoopback: allowsInsecureLoopback,
            rejectsNonOwnedProductHosts: true
        )
    }

    private static func validatedServiceURL(
        _ raw: String,
        allowsInsecureLoopback: Bool,
        rejectsNonOwnedProductHosts: Bool
    ) -> URL? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.path.isEmpty || url.path == "/",
              url.fragment == nil else {
            return nil
        }
        let loopbackHosts = Set(["localhost", "127.0.0.1", "::1", "[::1]"])
        let transportIsAllowed = scheme == "https"
            || (allowsInsecureLoopback && scheme == "http" && loopbackHosts.contains(host))
        guard transportIsAllowed else { return nil }

        if rejectsNonOwnedProductHosts {
            let rejectedHosts = Set([
                "github.com",
                "www.github.com",
                "github.io",
                "cmux.com",
                "www.cmux.com",
                "cmux.dev",
                "www.cmux.dev",
                "manaflow.com",
                "www.manaflow.com",
                "manaflow.ai",
                "www.manaflow.ai",
                "uniconnect.invalid",
            ])
            let rejectedSuffixes = [
                ".github.com",
                ".github.io",
                ".cmux.com",
                ".cmux.dev",
                ".manaflow.com",
                ".manaflow.ai",
                ".invalid",
            ]
            guard !rejectedHosts.contains(host),
                  !rejectedSuffixes.contains(where: host.hasSuffix) else {
                return nil
            }
        }
        return canonicalizedLoopbackURL(url)
    }

    private static func explicitlyEnabled(_ raw: String?) -> Bool {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on": true
        default: false
        }
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            return value
        case let value as Bool:
            return value ? "true" : "false"
        case let value as NSNumber:
            return value.boolValue ? "true" : "false"
        default:
            return nil
        }
    }

    private static func canonicalizedLoopbackURL(_ url: URL) -> URL {
        guard let host = url.host?.lowercased() else {
            return url
        }

        let loopbackHosts = ["127.0.0.1", "::1", "[::1]", "0.0.0.0"]
        guard loopbackHosts.contains(host) else {
            return url
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = "localhost"
        return components?.url ?? url
    }
}
