import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("UniConnect inert SSH config target resolution")
struct UniConnectSSHConfigTargetResolverTests {
    private struct Fixture {
        let root: URL
        let home: URL
        let userConfig: URL
        let systemConfig: URL

        init() throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("uniconnect-ssh-config-\(UUID().uuidString)", isDirectory: true)
            let homeURL = rootURL.appendingPathComponent("home", isDirectory: true)
            root = rootURL
            home = homeURL
            userConfig = homeURL.appendingPathComponent(".ssh/config")
            systemConfig = rootURL.appendingPathComponent("etc/ssh/ssh_config")
            try FileManager.default.createDirectory(
                at: userConfig.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: systemConfig.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        func write(_ text: String, to url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: url)
            try setMode(0o600, on: url)
        }

        func write(_ bytes: [UInt8], to url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(bytes).write(to: url)
            try setMode(0o600, on: url)
        }

        func resolver(
            defaultUser: String? = "local-account",
            limits: UniConnectSSHConfigTargetResolver.Limits = .init(),
            afterFileStat: (@Sendable (URL) throws -> Void)? = nil
        ) -> UniConnectSSHConfigTargetResolver {
            UniConnectSSHConfigTargetResolver(
                userConfigurationURL: userConfig,
                systemConfigurationURL: systemConfig,
                homeDirectoryURL: home,
                defaultUser: defaultUser,
                limits: limits,
                afterFileStat: afterFileStat
            )
        }

        private func setMode(_ mode: mode_t, on url: URL) throws {
            guard Darwin.chmod(url.path, mode) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test("Synchronous startup hydration uses the same inert parser as async import")
    func startupAndAsyncResolutionAgree() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(
            """
            Host legacy-alias
              HostName resolved.example.test
              User deploy
              Port 2207
            """,
            to: fixture.userConfig
        )
        let resolver = fixture.resolver()
        let requests = [UniConnectSSHTargetResolutionRequest(originalHost: "legacy-alias")]

        let startup = resolver.resolveForStartup(requests)
        let ordinary = await resolver.resolve(requests)

        #expect(startup == ordinary)
        #expect(startup == [.resolved(UniConnectSSHEffectiveTarget(
            user: "deploy",
            host: "resolved.example.test",
            port: 2207
        )!)])
    }

    @Test("CLI endpoint fields beat user and system config while the alias stays unchanged")
    func explicitValuesHaveHighestPrecedence() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(
            """
            Host production
              HostName user.example.test
              User user-config
              Port 2201
            """,
            to: fixture.userConfig
        )
        try fixture.write(
            """
            Host production
              HostName system.example.test
              User system-config
              Port 2202
            """,
            to: fixture.systemConfig
        )

        let request = UniConnectSSHTargetResolutionRequest(
            originalHost: "production",
            explicitUser: "cli-user",
            explicitHostName: "CLI.EXAMPLE.TEST.",
            explicitPort: 2222
        )
        let outcome = await fixture.resolver().resolve(request)
        #expect(outcome == .resolved(try target(user: "cli-user", host: "cli.example.test", port: 2222)))
        #expect(request.originalHost == "production")
    }

    @Test("User config precedes system config and every endpoint field is first-value-wins")
    func userAndFirstValuePrecedence() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(
            """
            Host production
              User deploy
              User ignored-user
              Port 2200
            """,
            to: fixture.userConfig
        )
        try fixture.write(
            """
            Host production
              HostName Origin.EXAMPLE.TEST.
              User ignored-system-user
              Port 2299
            """,
            to: fixture.systemConfig
        )

        let outcome = await fixture.resolver().resolve(.init(originalHost: "production"))
        #expect(outcome == .resolved(try target(user: "deploy", host: "origin.example.test", port: 2200)))
    }

    @Test("Missing config uses the injected passwd user, alias, and port 22")
    func defaultsAreInjectedAndNeverReadFromEnvironment() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outcome = await fixture.resolver(defaultUser: "passwd-user").resolve(
            .init(originalHost: "Alias.EXAMPLE.")
        )
        #expect(outcome == .resolved(try target(user: "passwd-user", host: "alias.example", port: 22)))

        let missingUser = await fixture.resolver(defaultUser: nil).resolve(
            .init(originalHost: "alias.example")
        )
        #expect(missingUser == .indeterminate)
    }

    @Test("Host wildcards are case-sensitive and a matching negation vetoes the block")
    func hostWildcardAndNegationSemantics() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(
            """
            Host *.CORP.EXAMPLE !BLOCKED.CORP.EXAMPLE
              HostName gateway.example.test
              User deploy
              Port 2200
            Host *
              User fallback
            """,
            to: fixture.userConfig
        )

        let outcomes = await fixture.resolver().resolve([
            .init(originalHost: "API.CORP.EXAMPLE"),
            .init(originalHost: "BLOCKED.CORP.EXAMPLE"),
        ])
        #expect(outcomes == [
            .resolved(try target(user: "deploy", host: "gateway.example.test", port: 2200)),
            .resolved(try target(user: "fallback", host: "blocked.corp.example", port: 22)),
        ])

        let differentlyCased = await fixture.resolver().resolve(
            .init(originalHost: "api.corp.example")
        )
        #expect(differentlyCased == .resolved(
            try target(user: "fallback", host: "api.corp.example", port: 22)
        ))
    }

    @Test("Host patterns are whitespace-separated and treat commas literally")
    func hostPatternsDoNotAcquireMatchCommaListSemantics() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(
            """
            Host production,staging
              HostName wrong.example.test
              User wrong-user
            Host production
              HostName correct.example.test
              User correct-user
            """,
            to: fixture.userConfig
        )

        #expect(await fixture.resolver().resolve(.init(originalHost: "production")) == .resolved(
            try target(user: "correct-user", host: "correct.example.test", port: 22)
        ))
    }

    @Test("Host matching preserves the command-line trailing-dot spelling")
    func hostMatchingDoesNotNormalizeBeforeSelectingStanzas() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(
            """
            Host production
              HostName wrong.example.test
              User wrong-user
            Host production.
              HostName correct.example.test
              User correct-user
              Port 2209
            """,
            to: fixture.userConfig
        )

        let outcome = await fixture.resolver().resolve(.init(originalHost: "production."))
        #expect(outcome == .resolved(
            try target(user: "correct-user", host: "correct.example.test", port: 2209)
        ))
    }

    @Test("Bracketed IPv6 Host patterns are literal and match the command-line spelling")
    func bracketedIPv6HostPatternIsSupported() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(
            """
            Host ::1
              User wrong-user
            Host [::1]
              User ipv6-user
              Port 2226
            """,
            to: fixture.userConfig
        )

        let outcome = await fixture.resolver().resolve(.init(originalHost: "[::1]"))
        #expect(outcome == .resolved(try target(user: "ipv6-user", host: "::1", port: 2226)))
    }

    @Test("Recursive Includes keep their root base when a glob has one match")
    func recursiveIncludesKeepTheirRootBase() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sshRoot = fixture.userConfig.deletingLastPathComponent()
        try fixture.write(
            """
            Host production
              Include conf.d/*.conf
            """,
            to: fixture.userConfig
        )
        try fixture.write(
            """
            HostName first.example.test
            Include nested/user.conf
            Port 2244
            """,
            to: sshRoot.appendingPathComponent("conf.d/10-first.conf")
        )
        try fixture.write(
            "User nested-user\n",
            to: sshRoot.appendingPathComponent("nested/user.conf")
        )

        let outcome = await fixture.resolver().resolve(.init(originalHost: "production"))
        #expect(outcome == .resolved(try target(user: "nested-user", host: "first.example.test", port: 2244)))
    }

    @Test("A glob with multiple matches fails closed instead of guessing collation order")
    func multipleGlobMatchesAreIndeterminate() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sshRoot = fixture.userConfig.deletingLastPathComponent()
        try fixture.write("Include conf.d/*.conf\n", to: fixture.userConfig)
        try fixture.write(
            "User first-user\n",
            to: sshRoot.appendingPathComponent("conf.d/a.conf")
        )
        try fixture.write(
            "User second-user\n",
            to: sshRoot.appendingPathComponent("conf.d/b.conf")
        )

        #expect(await fixture.resolver().resolve(.init(originalHost: "production")) == .indeterminate)
    }

    @Test("Every included file restores its parent Host applicability")
    func includedHostBlocksCannotLeakIntoSiblingsOrParent() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sshRoot = fixture.userConfig.deletingLastPathComponent()
        try fixture.write(
            """
            Host production
              Include first.conf second.conf
              HostName parent.example.test
              Port 2240
            """,
            to: fixture.userConfig
        )
        try fixture.write(
            """
            Host unrelated
              HostName must-not-leak.example.test
            """,
            to: sshRoot.appendingPathComponent("first.conf")
        )
        try fixture.write(
            """
            User included-user
            """,
            to: sshRoot.appendingPathComponent("second.conf")
        )

        let outcome = await fixture.resolver().resolve(.init(originalHost: "production"))
        #expect(outcome == .resolved(
            try target(user: "included-user", host: "parent.example.test", port: 2240)
        ))
    }

    @Test("Current-home Includes expand only from the injected home")
    func tildeIncludesUseInjectedHome() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("Include ~/.ssh/extra.conf\n", to: fixture.userConfig)
        try fixture.write(
            """
            Host alias
              HostName tilde.example.test
              User tilde-user
              Port 2022
            """,
            to: fixture.home.appendingPathComponent(".ssh/extra.conf")
        )

        let outcome = await fixture.resolver().resolve(.init(originalHost: "alias"))
        #expect(outcome == .resolved(try target(user: "tilde-user", host: "tilde.example.test", port: 2022)))
    }

    @Test("System configuration cannot expand a current-home Include")
    func systemTildeIncludesFailClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("Include ~/.ssh/system-home.conf\n", to: fixture.systemConfig)
        try fixture.write(
            "HostName must-not-resolve.example.test\nUser wrong-user\n",
            to: fixture.home.appendingPathComponent(".ssh/system-home.conf")
        )

        #expect(await fixture.resolver().resolve(.init(originalHost: "production")) == .indeterminate)
    }

    @Test("Equals, quotes, comments, question-mark patterns, and unrelated options stay inert")
    func lexicalFormsDoNotAcquireShellSemantics() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sshRoot = fixture.userConfig.deletingLastPathComponent()
        try fixture.write(
            "Include=\"conf dir/endpoint.conf\" # lexical include\n",
            to: fixture.userConfig
        )
        try fixture.write(
            """
            Host api?.example # one-character wildcard
              IdentityFile "~/.ssh/key with spaces"
              HostName=Resolved.Example.Test. # inline comment
              User=quoted-user
              Port=2323
            """,
            to: sshRoot.appendingPathComponent("conf dir/endpoint.conf")
        )

        let outcome = await fixture.resolver().resolve(.init(originalHost: "api1.example"))
        #expect(outcome == .resolved(
            try target(user: "quoted-user", host: "resolved.example.test", port: 2323)
        ))
    }

    @Test("Backslashes fail closed instead of retargeting Include paths or Host patterns")
    func backslashEscapesStaySemanticallyInert() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(
            "Include \\#endpoint.conf\n",
            to: fixture.userConfig
        )
        #expect(await fixture.resolver().resolve(.init(originalHost: "alias")) == .indeterminate)

        try fixture.write(
            "Host prod\\q\n  HostName must-not-match.example.test\n  User wrong-user\n",
            to: fixture.userConfig
        )
        #expect(await fixture.resolver().resolve(.init(originalHost: "prodq")) == .indeterminate)

        try fixture.write(
            "User must-not-be-read\n",
            to: fixture.userConfig.deletingLastPathComponent()
                .appendingPathComponent("conf dir/endpoint.conf")
        )
        try fixture.write("Include conf\\ dir/endpoint.conf\n", to: fixture.userConfig)
        #expect(await fixture.resolver().resolve(.init(originalHost: "alias")) == .indeterminate)
    }

    @Test("Inactive Includes are not opened")
    func inactiveIncludesCannotPoisonAnotherHost() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let poison = fixture.userConfig.deletingLastPathComponent().appendingPathComponent("poison.conf")
        try fixture.write(
            """
            Host another-host
              Include poison.conf
            Host production
              HostName safe.example.test
              User safe-user
            """,
            to: fixture.userConfig
        )
        try fixture.write(String(repeating: "X", count: 512), to: poison)
        let limits = UniConnectSSHConfigTargetResolver.Limits(maximumFileBytes: 256)

        let outcome = await fixture.resolver(limits: limits).resolve(.init(originalHost: "production"))
        #expect(outcome == .resolved(try target(user: "safe-user", host: "safe.example.test", port: 22)))
    }

    @Test("Static Match forms resolve, while dynamic Match can only be ignored after identity is fixed")
    func matchBlocksFailClosedWithoutExecuting() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let marker = fixture.root.appendingPathComponent("must-not-exist")
        try fixture.write(
            """
            Match originalhost production
              HostName matched.example.test
              User matched-user
              Port 2207
            Match originalhost production version OpenSSH_*
              HostName version-dependent.example.test
            Match exec "touch \(marker.path)"
              HostName attacker.example.test
            """,
            to: fixture.userConfig
        )

        let dynamicOutcome = await fixture.resolver().resolve(.init(originalHost: "other"))
        #expect(dynamicOutcome == .indeterminate)
        #expect(!FileManager.default.fileExists(atPath: marker.path))

        let fixedOutcome = await fixture.resolver().resolve(.init(
            originalHost: "other",
            explicitUser: "fixed-user",
            explicitHostName: "fixed.example.test",
            explicitPort: 2208
        ))
        #expect(fixedOutcome == .resolved(
            try target(user: "fixed-user", host: "fixed.example.test", port: 2208)
        ))
        #expect(!FileManager.default.fileExists(atPath: marker.path))

        let staticOutcome = await fixture.resolver().resolve(.init(originalHost: "production"))
        #expect(staticOutcome == .resolved(
            try target(user: "matched-user", host: "matched.example.test", port: 2207)
        ))

        try fixture.write(
            """
            Match originalhost production version OpenSSH_*
              HostName version-dependent.example.test
              User version-dependent-user
              Port 2229
            """,
            to: fixture.userConfig
        )
        #expect(await fixture.resolver().resolve(.init(originalHost: "production")) == .indeterminate)
    }

    @Test("A Host boundary after an irrelevant dynamic Match restores deterministic parsing")
    func hostBoundaryEndsUnknownMatchBlock() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(
            """
            Match exec "false"
              IdentityFile ~/.ssh/id_ed25519
            Host production
              HostName recovered.example.test
              User recovered-user
              Port 2223
            """,
            to: fixture.userConfig
        )

        let outcome = await fixture.resolver().resolve(.init(originalHost: "production"))
        #expect(outcome == .resolved(
            try target(user: "recovered-user", host: "recovered.example.test", port: 2223)
        ))
    }

    @Test("Canonical/final passes, DNS canonicalization, and expansion tokens are indeterminate")
    func unsupportedRuntimeResolutionFailsClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        try fixture.write(
            """
            Host production
              CanonicalizeHostname yes
              HostName canonical.example.test
              User deploy
            """,
            to: fixture.userConfig
        )
        #expect(await fixture.resolver().resolve(.init(originalHost: "production")) == .indeterminate)

        try fixture.write(
            """
            Match final
              HostName final.example.test
            """,
            to: fixture.userConfig
        )
        #expect(await fixture.resolver().resolve(.init(originalHost: "production")) == .indeterminate)

        try fixture.write(
            """
            Host production
              HostName %h.example.test
            """,
            to: fixture.userConfig
        )
        #expect(await fixture.resolver().resolve(.init(originalHost: "production")) == .indeterminate)

        try fixture.write("Include %d/.ssh/extra.conf\n", to: fixture.userConfig)
        #expect(await fixture.resolver().resolve(.init(originalHost: "production")) == .indeterminate)
    }

    @Test("CanonicalizeHostname no is first-value-wins across user and system config")
    func explicitCanonicalizationDisableIsDeterministic() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(
            """
            CanonicalizeHostname no
            Host production
              HostName direct.example.test
              User deploy
            """,
            to: fixture.userConfig
        )
        try fixture.write("CanonicalizeHostname yes\n", to: fixture.systemConfig)

        let outcome = await fixture.resolver().resolve(.init(originalHost: "production"))
        #expect(outcome == .resolved(try target(user: "deploy", host: "direct.example.test", port: 22)))
    }

    @Test("Malformed, cyclic, and non-UTF8 config never leaks a diagnostic payload")
    func malformedInputsAreIndeterminate() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let loop = fixture.userConfig.deletingLastPathComponent().appendingPathComponent("loop.conf")
        try fixture.write("Include loop.conf\n", to: fixture.userConfig)
        try fixture.write("Include config\n", to: loop)
        #expect(await fixture.resolver().resolve(.init(originalHost: "production")) == .indeterminate)

        try fixture.write([0xFF, 0xFE], to: fixture.userConfig)
        #expect(await fixture.resolver().resolve(.init(originalHost: "production")) == .indeterminate)

        try fixture.write([0x48, 0x6F, 0x73, 0x74, 0x00, 0x20, 0x2A], to: fixture.userConfig)
        #expect(await fixture.resolver().resolve(.init(originalHost: "production")) == .indeterminate)

        try fixture.write("Host production\n  Port 70000\n", to: fixture.userConfig)
        #expect(await fixture.resolver().resolve(.init(originalHost: "production")) == .indeterminate)

        try fixture.write("User 'deploy'\n", to: fixture.userConfig)
        #expect(await fixture.resolver().resolve(.init(originalHost: "production")) == .indeterminate)
    }

    @Test("Malformed endpoint directives fail closed after first values and in inactive blocks")
    func endpointDirectiveSyntaxIsAlwaysValidated() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        try fixture.write("User first-user\nUser second-user extra\n", to: fixture.userConfig)
        #expect(await fixture.resolver().resolve(.init(originalHost: "production")) == .indeterminate)

        try fixture.write("User first-user\nUser bad$user\n", to: fixture.userConfig)
        #expect(await fixture.resolver().resolve(.init(originalHost: "production")) == .indeterminate)

        try fixture.write(
            "HostName first.example.test\nHostName\nUser deploy\n",
            to: fixture.userConfig
        )
        #expect(await fixture.resolver().resolve(.init(originalHost: "production")) == .indeterminate)

        try fixture.write(
            "HostName first.example.test\nHostName %h\nUser deploy\n",
            to: fixture.userConfig
        )
        #expect(await fixture.resolver().resolve(.init(originalHost: "production")) == .indeterminate)

        try fixture.write("Port 2200\nPort invalid\nUser deploy\n", to: fixture.userConfig)
        #expect(await fixture.resolver().resolve(.init(originalHost: "production")) == .indeterminate)

        try fixture.write(
            "CanonicalizeHostname no\nCanonicalizeHostname unknown\nUser deploy\n",
            to: fixture.userConfig
        )
        #expect(await fixture.resolver().resolve(.init(originalHost: "production")) == .indeterminate)

        try fixture.write(
            "Host another-host\n  Port invalid\nHost production\n  User deploy\n",
            to: fixture.userConfig
        )
        #expect(await fixture.resolver().resolve(.init(originalHost: "production")) == .indeterminate)

        try fixture.write(
            "Host another-host\n  User bad$user\nHost production\n  User deploy\n",
            to: fixture.userConfig
        )
        #expect(await fixture.resolver().resolve(.init(originalHost: "production")) == .indeterminate)
    }

    @Test("Config loading rejects FIFOs and group/world-writable files")
    func configFileTypeAndModeAreValidatedOnTheOpenDescriptor() async throws {
        let fifoFixture = try Fixture()
        defer { fifoFixture.remove() }
        #expect(Darwin.mkfifo(fifoFixture.userConfig.path, 0o600) == 0)
        let fifoKeeper = Darwin.open(
            fifoFixture.userConfig.path,
            O_RDWR | O_NONBLOCK | O_CLOEXEC
        )
        guard fifoKeeper >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { _ = Darwin.close(fifoKeeper) }
        #expect(await fifoFixture.resolver().resolve(.init(originalHost: "production")) == .indeterminate)

        let writableFixture = try Fixture()
        defer { writableFixture.remove() }
        try writableFixture.write("User unsafe\n", to: writableFixture.userConfig)
        #expect(Darwin.chmod(writableFixture.userConfig.path, 0o666) == 0)
        #expect(await writableFixture.resolver().resolve(
            .init(originalHost: "production")
        ) == .indeterminate)
    }

    @Test("A file that grows after fstat is read only through the byte limit plus one")
    func growthAfterMetadataCheckFailsClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("User x\n", to: fixture.userConfig)
        let configPath = fixture.userConfig.path
        let limits = UniConnectSSHConfigTargetResolver.Limits(
            maximumTotalBytes: 7,
            maximumFileBytes: 7
        )

        let baseline = await fixture.resolver(limits: limits).resolve(
            .init(originalHost: "production")
        )
        #expect(baseline == .resolved(try target(user: "x", host: "production", port: 22)))

        let growingResolver = fixture.resolver(
            limits: limits,
            afterFileStat: { openedURL in
                guard openedURL.path == configPath else { return }
                try appendBytes([0x23], toPath: configPath)
            }
        )
        #expect(await growingResolver.resolve(
            .init(originalHost: "production")
        ) == .indeterminate)
        #expect(try Data(contentsOf: fixture.userConfig).count == 8)
    }

    @Test("Replacing the config path after fstat cannot swap the descriptor's bytes")
    func pathReplacementAfterMetadataCheckCannotRetargetTheRead() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let openedPath = fixture.userConfig.path
        let archivedPath = fixture.root.appendingPathComponent("opened-config").path
        let replacementURL = fixture.root.appendingPathComponent("replacement-config")
        let replacementPath = replacementURL.path
        try fixture.write("User descriptor-user\n", to: fixture.userConfig)
        try fixture.write("User path-swap-user\n", to: replacementURL)

        let resolver = fixture.resolver(afterFileStat: { openedURL in
            guard openedURL.path == openedPath else { return }
            try renamePath(openedPath, to: archivedPath)
            try renamePath(replacementPath, to: openedPath)
        })
        #expect(await resolver.resolve(.init(originalHost: "production")) == .resolved(
            try target(user: "descriptor-user", host: "production", port: 22)
        ))
    }

    @Test("Invalid UTF-8 bytes consume the shared batch byte budget")
    func invalidInputIsChargedBeforeParsing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(Array(repeating: 0xFF, count: 8), to: fixture.userConfig)
        let configPath = fixture.userConfig.path
        let markerPath = fixture.root.appendingPathComponent("first-read.marker").path
        let replacement = Array("User x\n".utf8)
        let resolver = fixture.resolver(
            limits: .init(maximumTotalBytes: 8, maximumFileBytes: 8),
            afterFileStat: { openedURL in
                guard openedURL.path == configPath else { return }
                if try createExclusiveMarker(atPath: markerPath) { return }
                try overwriteBytes(replacement, atPath: configPath)
            }
        )

        let outcomes = await resolver.resolve([
            .init(originalHost: "first"),
            .init(originalHost: "second"),
        ])
        #expect(outcomes == [.indeterminate, .indeterminate])
        #expect(await fixture.resolver(
            limits: .init(maximumTotalBytes: 8, maximumFileBytes: 8)
        ).resolve(.init(originalHost: "second")) == .resolved(
            try target(user: "x", host: "second", port: 22)
        ))
    }

    @Test("Hard-linked Includes share inode cache and file-count accounting")
    func loadedFileCacheUsesDescriptorIdentity() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sshRoot = fixture.userConfig.deletingLastPathComponent()
        let first = sshRoot.appendingPathComponent("first.conf")
        let second = sshRoot.appendingPathComponent("second.conf")
        try fixture.write("Include first.conf second.conf\n", to: fixture.userConfig)
        try fixture.write("User inode-user\n", to: first)
        try FileManager.default.linkItem(at: first, to: second)

        let outcome = await fixture.resolver(limits: .init(maximumFiles: 2)).resolve(
            .init(originalHost: "production")
        )
        #expect(outcome == .resolved(
            try target(user: "inode-user", host: "production", port: 22)
        ))
    }

    @Test("Depth, file-count, and include-match ceilings fail closed")
    func traversalLimitsAreEnforced() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sshRoot = fixture.userConfig.deletingLastPathComponent()
        try fixture.write("Include one.conf\n", to: fixture.userConfig)
        try fixture.write("Include two.conf\n", to: sshRoot.appendingPathComponent("one.conf"))
        try fixture.write("User deploy\n", to: sshRoot.appendingPathComponent("two.conf"))

        let depthLimited = fixture.resolver(limits: .init(maximumIncludeDepth: 1))
        #expect(await depthLimited.resolve(.init(originalHost: "production")) == .indeterminate)

        let fileLimited = fixture.resolver(limits: .init(maximumFiles: 2))
        #expect(await fileLimited.resolve(.init(originalHost: "production")) == .indeterminate)

        try fixture.write("Include many/*.conf\n", to: fixture.userConfig)
        try fixture.write("User one\n", to: sshRoot.appendingPathComponent("many/1.conf"))
        try fixture.write("User two\n", to: sshRoot.appendingPathComponent("many/2.conf"))
        let matchLimited = fixture.resolver(limits: .init(maximumIncludeMatches: 1))
        #expect(await matchLimited.resolve(.init(originalHost: "production")) == .indeterminate)

        let directoryLimited = fixture.resolver(limits: .init(
            maximumIncludeMatches: 10,
            maximumDirectoryEntries: 1
        ))
        #expect(await directoryLimited.resolve(.init(originalHost: "production")) == .indeterminate)

        let missingIncludes = (0..<64)
            .map { "Include missing-\($0).conf" }
            .joined(separator: "\n")
        try fixture.write(missingIncludes, to: fixture.userConfig)
        let includeWorkLimited = fixture.resolver(limits: .init(maximumIncludeWork: 24))
        #expect(await includeWorkLimited.resolve(.init(originalHost: "production")) == .indeterminate)

        try fixture.write(
            Array(repeating: "Include repeated-missing.conf", count: 64).joined(separator: "\n"),
            to: fixture.userConfig
        )
        let cachedMissLimited = fixture.resolver(limits: .init(maximumIncludeWork: 24))
        #expect(await cachedMissLimited.resolve(.init(originalHost: "production")) == .indeterminate)
    }

    @Test("Byte, line, directive, token, and batch ceilings fail closed")
    func parsingAndBatchLimitsAreEnforced() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        try fixture.write("User deploy\nHostName target\n", to: fixture.userConfig)
        let fileLimited = fixture.resolver(limits: .init(
            maximumTotalBytes: 64,
            maximumFileBytes: 20
        ))
        #expect(await fileLimited.resolve(.init(originalHost: "production")) == .indeterminate)

        let sshRoot = fixture.userConfig.deletingLastPathComponent()
        try fixture.write("Include part.conf\n", to: fixture.userConfig)
        try fixture.write("User deploy\n", to: sshRoot.appendingPathComponent("part.conf"))
        let totalLimited = fixture.resolver(limits: .init(
            maximumTotalBytes: 25,
            maximumFileBytes: 25
        ))
        #expect(await totalLimited.resolve(.init(originalHost: "production")) == .indeterminate)

        try fixture.write("User deploy\nHostName target\n", to: fixture.userConfig)
        let lineLimited = fixture.resolver(limits: .init(maximumLineBytes: 8))
        #expect(await lineLimited.resolve(.init(originalHost: "production")) == .indeterminate)

        let directiveLimited = fixture.resolver(limits: .init(maximumDirectives: 1))
        #expect(await directiveLimited.resolve(.init(originalHost: "production")) == .indeterminate)

        try fixture.write("Host one two three\n", to: fixture.userConfig)
        let tokenLimited = fixture.resolver(limits: .init(maximumTokensPerLine: 2))
        #expect(await tokenLimited.resolve(.init(originalHost: "production")) == .indeterminate)

        let batchLimited = fixture.resolver(limits: .init(maximumRequests: 1))
        let outcomes = await batchLimited.resolve([
            .init(originalHost: "one"),
            .init(originalHost: "two"),
        ])
        #expect(outcomes == [.indeterminate, .indeterminate])

        try fixture.write("Host *\n  User deploy\n", to: fixture.userConfig)
        let patternWorkLimited = fixture.resolver(limits: .init(maximumPatternWork: 2))
        #expect(await patternWorkLimited.resolve(.init(originalHost: "production")) == .indeterminate)

        let maximumPattern = String(repeating: "*", count: 1_022)
        try fixture.write(
            "Match originalhost \(maximumPattern)\n  HostName accepted.example.test\n  User accepted-user\n",
            to: fixture.userConfig
        )
        #expect(await fixture.resolver().resolve(.init(originalHost: "production")) == .resolved(
            try target(user: "accepted-user", host: "accepted.example.test", port: 22)
        ))

        let oversizedPattern = String(repeating: "*", count: 1_023)
        try fixture.write(
            "Match originalhost \(oversizedPattern)\n  HostName wrong.example.test\n  User wrong-user\n",
            to: fixture.userConfig
        )
        #expect(await fixture.resolver().resolve(.init(originalHost: "production")) == .indeterminate)
    }

    @Test("Validated commands expose explicit identity without rewriting their alias")
    func validatedCommandFeedsEffectiveTargetKey() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let validated = try #require(UniConnectSSHConnectCommandValidator().validatedCommand(
            "ssh -o HostName=REAL.EXAMPLE.TEST. -o User=deploy -p 2222 production"
        ))
        let request = try #require(validated.targetResolutionRequest())
        #expect(request.originalHost == "production")
        #expect(validated.detectedSession()?.destination == "deploy@production")

        let outcome = await fixture.resolver().resolve(request)
        let effective = try #require(outcome.resolvedValue)
        let expected = try target(user: "deploy", host: "real.example.test", port: 2222)
        #expect(effective == expected)
        let key = try #require(UniConnectSSHTargetKey(effectiveTarget: effective, tmuxSession: "main"))
        #expect(key.username == "deploy")
        #expect(key.host == "real.example.test")
        #expect(key.port == 2222)
        #expect(key.tmuxSession == "main")

        let canonicalizing = try #require(UniConnectSSHConnectCommandValidator().validatedCommand(
            "ssh -o CanonicalizeHostname=yes production"
        ))
        #expect(canonicalizing.targetResolutionRequest() == nil)
    }

    @Test("Config-derived targets pin invocations before the alias without exposing passwords")
    func resolvedTargetPinsProcessAndShellInvocations() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(
            "Host production\n  HostName pinned.example.test\n  User deploy\n  Port 2205\n",
            to: fixture.userConfig
        )
        let validated = try #require(UniConnectSSHConnectCommandValidator().validatedCommand(
            "ssh -o Compression=yes production"
        ))
        let request = try #require(validated.targetResolutionRequest())
        let outcome = await fixture.resolver().resolve(request)
        let effectiveTarget = try #require(outcome.resolvedValue)

        let invocation = try #require(validated.invocation(
            injecting: ["-T"],
            pinnedTo: effectiveTarget,
            ambientEnvironment: [:]
        ))
        #expect(invocation.executable == "/usr/bin/ssh")
        #expect(invocation.arguments == [
            "-o", "CanonicalizeHostname=no",
            "-o", "HostName=pinned.example.test",
            "-o", "User=deploy",
            "-o", "Port=2205",
            "-o", "Compression=yes",
            "-T",
            "production",
        ])

        let shellCommand = try #require(validated.sensitiveCanonicalShellCommand(
            injecting: ["-T"],
            pinnedTo: effectiveTarget,
            ambientEnvironment: [:]
        ))
        #expect(shellCommand.contains("'CanonicalizeHostname=no'"))
        #expect(shellCommand.contains("'HostName=pinned.example.test'"))
        #expect(shellCommand.contains("'User=deploy'"))
        #expect(shellCommand.contains("'Port=2205'"))

        let password = "vault-only-password"
        let passwordCommand = try #require(UniConnectSSHConnectCommandValidator(
            isExecutableFile: { _ in true }
        ).validatedCommand("sshpass -p \(password) ssh production"))
        let passwordInvocation = try #require(passwordCommand.invocation(
            pinnedTo: effectiveTarget,
            ambientEnvironment: [:]
        ))
        #expect(passwordInvocation.environment["SSHPASS"] == password)
        #expect(!([passwordInvocation.executable] + passwordInvocation.arguments)
            .contains(where: { $0.contains(password) }))
        #expect(!effectiveTarget.sshPinningOptions.contains(where: { $0.contains(password) }))
    }

    @Test("Validated command endpoint options follow OpenSSH first-value precedence")
    func validatedCommandUsesFirstEndpointValueAcrossSpellings() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let validated = try #require(UniConnectSSHConnectCommandValidator().validatedCommand(
            "ssh -o User=first-user -l second-user -o Port=2201 -p 2202 "
                + "-o HostName=FIRST.EXAMPLE.TEST. -o HostName=second.example.test third@production"
        ))
        let request = try #require(validated.targetResolutionRequest())
        #expect(request.originalHost == "production")
        #expect(request.explicitUser == "first-user")
        #expect(request.explicitPort == 2201)
        #expect(request.explicitHostName == "FIRST.EXAMPLE.TEST.")

        let outcome = await fixture.resolver().resolve(request)
        #expect(outcome == .resolved(
            try target(user: "first-user", host: "first.example.test", port: 2201)
        ))
    }

    @Test("Explicit canonicalization disable wins before config and later CLI values")
    func explicitCanonicalizationDisableSurvivesConfigResolution() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(
            """
            CanonicalizeHostname yes
            Host production
              HostName direct.example.test
              User deploy
            """,
            to: fixture.userConfig
        )
        let disabled = try #require(UniConnectSSHConnectCommandValidator().validatedCommand(
            "ssh -o CanonicalizeHostname=no -o CanonicalizeHostname=yes production"
        ))
        let request = try #require(disabled.targetResolutionRequest())
        #expect(request.explicitCanonicalizeHostname == false)
        #expect(await fixture.resolver().resolve(request) == .resolved(
            try target(user: "deploy", host: "direct.example.test", port: 22)
        ))

        let enabledFirst = try #require(UniConnectSSHConnectCommandValidator().validatedCommand(
            "ssh -o CanonicalizeHostname=yes -o CanonicalizeHostname=no production"
        ))
        #expect(enabledFirst.targetResolutionRequest() == nil)

        let falseFirst = try #require(UniConnectSSHConnectCommandValidator().validatedCommand(
            "ssh -o CanonicalizeHostname=false -o CanonicalizeHostname=true production"
        ))
        #expect(falseFirst.targetResolutionRequest()?.explicitCanonicalizeHostname == false)
        let trueFirst = try #require(UniConnectSSHConnectCommandValidator().validatedCommand(
            "ssh -o CanonicalizeHostname=true -o CanonicalizeHostname=false production"
        ))
        #expect(trueFirst.targetResolutionRequest() == nil)

        let malformedLater = try #require(UniConnectSSHConnectCommandValidator().validatedCommand(
            "ssh -o CanonicalizeHostname=no -o CanonicalizeHostname=unknown production"
        ))
        #expect(malformedLater.targetResolutionRequest() == nil)
    }

    @Test("CLI endpoint fields and option grammar are ASCII-only")
    func targetResolutionScannerRejectsNonASCIIEndpointSpellings() throws {
        let validator = UniConnectSSHConnectCommandValidator()
        let commands = [
            "ssh -l usér production",
            "ssh -o User=deploy -l usér production",
            "ssh -o User=usér production",
            "ssh -o HostName=höst.example production",
            "ssh -o 'User\u{00A0}deploy' production",
            "ssh -o Üser=deploy production",
        ]
        for command in commands {
            let validated = try #require(validator.validatedCommand(command))
            #expect(validated.targetResolutionRequest() == nil)
        }

        let unrelated = try #require(validator.validatedCommand(
            "ssh -o Compression=yes production"
        ))
        #expect(unrelated.targetResolutionRequest()?.originalHost == "production")
    }

    @Test("Invalid explicit endpoint fields fail closed before config is consulted")
    func invalidExplicitEndpointIsIndeterminate() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(
            """
            Host *
              HostName safe.example.test
              User safe-user
              Port 22
            """,
            to: fixture.userConfig
        )
        let resolver = fixture.resolver()
        let outcomes = await resolver.resolve([
            .init(originalHost: "bad host"),
            .init(originalHost: "valid", explicitUser: "bad user"),
            .init(originalHost: "valid", explicitHostName: "%h.example"),
            .init(originalHost: "valid", explicitPort: 0),
            .init(originalHost: "valid", explicitCanonicalizeHostname: true),
        ])
        #expect(outcomes == Array(repeating: .indeterminate, count: 5))
    }

    private func target(
        user: String,
        host: String,
        port: Int
    ) throws -> UniConnectSSHEffectiveTarget {
        try #require(UniConnectSSHEffectiveTarget(user: user, host: host, port: port))
    }
}

private extension UniConnectSSHTargetResolutionOutcome {
    var resolvedValue: UniConnectSSHEffectiveTarget? {
        guard case .resolved(let target) = self else { return nil }
        return target
    }
}

private func appendBytes(_ bytes: [UInt8], toPath path: String) throws {
    try writeBytes(bytes, toPath: path, flags: O_WRONLY | O_APPEND | O_CLOEXEC)
}

private func overwriteBytes(_ bytes: [UInt8], atPath path: String) throws {
    try writeBytes(bytes, toPath: path, flags: O_WRONLY | O_TRUNC | O_CLOEXEC)
}

private func writeBytes(_ bytes: [UInt8], toPath path: String, flags: Int32) throws {
    let descriptor = Darwin.open(path, flags)
    let openError = errno
    guard descriptor >= 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(openError))
    }
    defer { _ = Darwin.close(descriptor) }

    try bytes.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var offset = 0
        while offset < rawBuffer.count {
            let count = Darwin.write(
                descriptor,
                baseAddress.advanced(by: offset),
                rawBuffer.count - offset
            )
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            offset += count
        }
    }
}

private func createExclusiveMarker(atPath path: String) throws -> Bool {
    let descriptor = Darwin.open(
        path,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
        mode_t(0o600)
    )
    let openError = errno
    if descriptor >= 0 {
        _ = Darwin.close(descriptor)
        return true
    }
    if openError == EEXIST { return false }
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(openError))
}

private func renamePath(_ source: String, to destination: String) throws {
    guard Darwin.rename(source, destination) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
