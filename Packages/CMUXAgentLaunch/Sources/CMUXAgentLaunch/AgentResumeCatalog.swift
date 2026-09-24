import Foundation

/// Decodes the command syntax resource consumed by both desktop adapters.
struct AgentResumeCatalog: Decodable, Sendable, Equatable {
    let schemaVersion: Int
    let providers: [String: Provider]

    struct Provider: Decodable, Sendable, Equatable {
        let executable: String
        let aliases: [String]?
        let resume: [String]
        let windowOptions: [WindowOption]?
        /// The flags and environment that make a resumed agent run without asking; absent when
        /// no such mode is verified for this provider.
        let noPrompt: NoPrompt?
    }

    /// The provider's "never stop on a question" mode, shared with Linux and the VPS supervisor.
    ///
    /// `prefix` goes right after the executable, `suffix` at the end, `legacy` lists older
    /// spellings of the same mode that are removed before inserting the current ones, and
    /// `rootEnvironment` is only exported when the agent runs as root.
    struct NoPrompt: Decodable, Sendable, Equatable {
        let prefix: [String]?
        let suffix: [String]?
        let legacy: [String]?
        let rootEnvironment: [String: String]?

        /// Every flag the policy knows, current or legacy, so previous occurrences can be removed.
        var allFlags: Set<String> {
            Set((prefix ?? []) + (suffix ?? []) + (legacy ?? []))
        }

        /// Whether every flag is a plain option and every environment entry is a safe `K=V`.
        var isValid: Bool {
            let flags = (prefix ?? []) + (suffix ?? []) + (legacy ?? [])
            let flagsAreOptions = flags.allSatisfy { flag in
                flag.count > 1 && flag.hasPrefix("-") && !flag.contains("{") && !flag.contains("\0")
                    && !flag.contains(where: \.isWhitespace)
            }
            guard flagsAreOptions else { return false }
            for (key, value) in rootEnvironment ?? [:] {
                guard key.range(of: #"^[A-Z_][A-Z0-9_]*$"#, options: .regularExpression) != nil,
                      value.range(of: #"^[A-Za-z0-9._-]{1,64}$"#, options: .regularExpression) != nil else {
                    return false
                }
            }
            return true
        }
    }

    struct WindowOption: Decodable, Sendable, Equatable {
        let field: String
        let option: String
    }

    enum CatalogError: Error {
        case missingResource
        case invalidSchema
    }

    init(locator: AgentResumeResourceLocator = AgentResumeResourceLocator()) throws {
        // Bundle.module traps when a copied CLI cannot find its build-time bundle;
        // never evaluate it, even inside try?. Missing deployment data is recoverable.
        guard let url = locator.resourceURL() else {
            throw CatalogError.missingResource
        }
        try self.init(data: Data(contentsOf: url))
    }

    init(data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
        guard schemaVersion == 1, !providers.isEmpty else { throw CatalogError.invalidSchema }
        var identifiers = Set(providers.keys)
        for provider in providers.values {
            guard !provider.executable.isEmpty,
                  provider.resume.first == "{executable}",
                  ["{executable}", "{sessionId}", "{arguments}"].allSatisfy({ token in
                      provider.resume.filter { $0 == token }.count == 1
                  }),
                  provider.resume.allSatisfy({ token in
                      !token.contains("\0") && (!token.contains("{") || ["{executable}", "{sessionId}", "{arguments}"].contains(token))
                  }) else { throw CatalogError.invalidSchema }
            for alias in provider.aliases ?? [] {
                guard !alias.isEmpty, identifiers.insert(alias).inserted else { throw CatalogError.invalidSchema }
            }
            for option in provider.windowOptions ?? [] {
                guard ["cwd", "model"].contains(option.field), option.option.hasPrefix("-") else {
                    throw CatalogError.invalidSchema
                }
            }
            if let noPrompt = provider.noPrompt, !noPrompt.isValid {
                throw CatalogError.invalidSchema
            }
        }
    }

    func canonicalKind(_ kind: String) -> String? {
        if providers[kind] != nil { return kind }
        return providers.first { $0.value.aliases?.contains(kind) == true }?.key
    }

    func argv(kind: String, sessionId: String, executable: String, arguments: [String]) -> [String]? {
        guard let canonical = canonicalKind(kind), let provider = providers[canonical] else { return nil }
        return provider.resume.flatMap { token -> [String] in
            switch token {
            case "{executable}": return [executable]
            case "{sessionId}": return [sessionId]
            case "{arguments}": return arguments
            default: return [token]
            }
        }
    }
}
