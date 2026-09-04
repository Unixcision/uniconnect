import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("UniConnect SSH connect-command validation")
struct UniConnectSSHConnectCommandValidatorTests {
    private let validator = UniConnectSSHConnectCommandValidator()

    @Test("Supported SSH and sshpass invocations remain valid")
    func acceptsSupportedConnectionCommands() {
        let commands = [
            "ssh root@203.0.113.7",
            "/usr/bin/ssh -t -i '/tmp/key with space.pem' -p 2222 -J jump@bastion root@host",
            "ssh -o StrictHostKeyChecking=no -o 'ProxyJump jump@bastion' root@host",
            "ssh -i $HOME/.ssh/id_ed25519 root@host",
            "ssh -i ${HOME}/.ssh/id_ed25519 root@host",
            "sshpass -P 'Password:' -p 'semi;pipe|dollar$(literal)' ssh root@host",
            "ssh -- host-alias",
        ]

        for command in commands {
            #expect(validator.validate(command) == nil, "Expected supported command: \(command)")
        }

        let trustedWrapperValidator = UniConnectSSHConnectCommandValidator(
            isExecutableFile: { $0 == "/opt/homebrew/bin/sshpass" }
        )
        #expect(trustedWrapperValidator.validate(
            "/opt/homebrew/bin/sshpass -psecret /usr/bin/ssh -v root@[2001:db8::1]"
        ) == nil)

        let macPortsWrapperValidator = UniConnectSSHConnectCommandValidator(
            isExecutableFile: { $0 == "/opt/local/bin/sshpass" }
        )
        #expect(macPortsWrapperValidator.validate(
            "/opt/local/bin/sshpass -psecret /usr/bin/ssh root@example.test"
        ) == nil)
    }

    @Test("Executable paths are exact, never accepted by basename")
    func rejectsArbitraryOrMissingExecutablePaths() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-untrusted-ssh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let fakeSSH = temporary.appendingPathComponent("ssh")
        try FileManager.default.createSymbolicLink(at: fakeSSH, withDestinationURL: URL(fileURLWithPath: "/usr/bin/ssh"))
        let fakeSSHPass = temporary.appendingPathComponent("sshpass")
        try FileManager.default.createSymbolicLink(at: fakeSSHPass, withDestinationURL: URL(fileURLWithPath: "/usr/bin/ssh"))

        #expect(validator.validate("\(fakeSSH.path) root@example.test") == .unsupportedExecutable)
        #expect(validator.validate("\(fakeSSHPass.path) -p secret ssh root@example.test") == .unsupportedExecutable)
        #expect(validator.validate("sshpass -p secret \(fakeSSH.path) root@example.test") == .invalidSSHPasswordWrapper)
        #expect(validator.validate("/usr/local/bin/ssh root@example.test") == .unsupportedExecutable)
        #expect(validator.validate("/usr/bin/../bin/ssh root@example.test") == .unsupportedExecutable)
        #expect(validator.validate(
            "/opt/homebrew/bin/../bin/sshpass -p secret ssh root@example.test"
        ) == .unsupportedExecutable)

        let noInstalledWrappers = UniConnectSSHConnectCommandValidator(isExecutableFile: { _ in false })
        #expect(noInstalledWrappers.validate(
            "/opt/homebrew/bin/sshpass -p secret ssh root@example.test"
        ) == .unsupportedExecutable)
        // The portable spelling may be stored on a Mac before sshpass is installed; it
        // validates, but cannot produce a launch invocation until a trusted copy exists.
        #expect(noInstalledWrappers.validate("sshpass -p secret ssh root@example.test") == nil)
        let parsed = try #require(noInstalledWrappers.validatedCommand(
            "sshpass -p secret ssh root@example.test"
        ))
        #expect(parsed.invocation(injecting: []) == nil)
    }

    @Test("Active shell operators and substitutions are rejected")
    func rejectsActiveShellSyntax() {
        let commands = [
            "ssh root@host | sh",
            "ssh root@host || touch /tmp/pwn",
            "ssh root@host; touch /tmp/pwn",
            "ssh root@host && touch /tmp/pwn",
            "ssh root@host > /tmp/output",
            "ssh root@host < /tmp/input",
            "ssh $(printf root@host)",
            "ssh `printf root@host`",
            "ssh $HOST",
            "ssh ${HOST}",
            "ssh root@ho*",
        ]

        for command in commands {
            #expect(validator.validate(command) == .unsafeShellSyntax, "Expected unsafe shell syntax: \(command)")
        }
        #expect(validator.validate("ssh root@host\nwhoami") == .lineBreak)
    }

    @Test("Malformed shell quoting is rejected")
    func rejectsMalformedQuoting() {
        #expect(validator.validate("ssh 'root@host") == .malformedQuoting)
        #expect(validator.validate("ssh \"root@host") == .malformedQuoting)
        #expect(validator.validate("ssh root@host\\") == .malformedQuoting)
    }

    @Test("sshpass must directly launch SSH after its own parsed options")
    func rejectsIndirectOrMissingSSHPasswordPayloads() {
        let commands = [
            "sshpass -p secret",
            "sshpass -p secret sh -c 'ssh root@host'",
            "sshpass -p secret echo ssh root@host",
            "sshpass -x ssh root@host",
            "sshpass -p",
        ]

        for command in commands {
            #expect(
                validator.validate(command) == .invalidSSHPasswordWrapper,
                "Expected invalid sshpass wrapper: \(command)"
            )
        }
        #expect(validator.validate("sshpass -p secret ssh") == .missingDestination)
        #expect(validator.validate("sshpass -e ssh root@host") == .invalidSSHPasswordWrapper)
        #expect(validator.validate("sshpass -f /tmp/password ssh root@host") == .invalidSSHPasswordWrapper)
        #expect(validator.validate("sshpass -d 3 ssh root@host") == .invalidSSHPasswordWrapper)
    }

    @Test("Remote commands and SSH options capable of local execution are rejected")
    func rejectsUnsafeSSHPayloads() {
        #expect(validator.validate("ssh root@host 'uname -a'") == .remoteCommand)
        #expect(validator.validate("ssh root@host -- harmless") == .remoteCommand)
        #expect(validator.validate("ssh -o ProxyCommand='sh -c whoami' root@host") == .unsafeSSHOption)
        #expect(validator.validate("ssh -oLocalCommand=whoami root@host") == .unsafeSSHOption)
        #expect(validator.validate("ssh -F /tmp/ssh_config root@host") == .unsafeSSHOption)
        #expect(validator.validate("ssh -L 8080:localhost:80 root@host") == .unsafeSSHOption)
        #expect(validator.validate("ssh -S /tmp/control.sock root@host") == .unsafeSSHOption)
        #expect(validator.validate("ssh -A root@host") == .unsafeSSHOption)
        #expect(validator.validate("ssh -X root@host") == .unsafeSSHOption)
        #expect(validator.validate("ssh -N root@host") == .unsafeSSHOption)
        #expect(validator.validate("ssh -o ForwardAgent=yes root@host") == .unsafeSSHOption)
        #expect(validator.validate("ssh -oLocalForward=8080:localhost:80 root@host") == .unsafeSSHOption)
        #expect(validator.validate("ssh -oRequestTTY=force root@host") == .unsafeSSHOption)
        #expect(validator.validate("ssh -oSetEnv=TOKEN=secret root@host") == .unsafeSSHOption)
        #expect(validator.validate("ssh 'root@host;touch'") == .invalidDestination)
        #expect(validator.validate("ssh -J 'jump;touch' root@host") == .invalidDestination)
        #expect(validator.validate("ssh -o 'ProxyJump=jump;touch' root@host") == .invalidDestination)
    }

    @Test("Destinations and options must form a complete SSH invocation")
    func rejectsIncompleteOrMalformedSSHInvocations() {
        #expect(validator.validate("") == .empty)
        #expect(validator.validate("ssh") == .missingDestination)
        #expect(validator.validate("ssh -p nope root@host") == .unsupportedSSHOption)
        #expect(validator.validate("ssh -p 70000 root@host") == .unsupportedSSHOption)
        #expect(validator.validate("ssh -Z root@host") == .unsupportedSSHOption)
        #expect(validator.validate("ssh -- -oProxyCommand=whoami") == .invalidDestination)
        #expect(validator.validate("bash -c 'ssh root@host'") == .unsupportedExecutable)
    }

    @Test("The product validation entry point uses the hardened validator")
    func integratesWithUniConnectSSHValidation() {
        #expect(UniConnectSSH.validateConnectCommand("ssh -J jump root@host") == nil)
        #expect(UniConnectSSH.validateConnectCommand("ssh root@host; touch /tmp/pwn") != nil)
        #expect(UniConnectSSH.validateConnectCommand("sshpass -p secret sh -c 'ssh root@host'") != nil)
    }

    @Test("Canonical argv pins SSH and keeps sshpass password out of arguments")
    func canonicalInvocationDoesNotReuseImportedExecutableOrPasswordArgv() throws {
        let validator = UniConnectSSHConnectCommandValidator(
            isExecutableFile: { $0 == "/opt/homebrew/bin/sshpass" }
        )
        let parsed = try #require(validator.validatedCommand(
            "sshpass -v -P 'Pass phrase:' -p 'top secret' /usr/bin/ssh -i $HOME/.ssh/key -- root@example.test"
        ))
        let invocation = try #require(parsed.invocation(
            injecting: ["-T", "-o", "ConnectTimeout=15"],
            remoteCommand: "sh -s",
            ambientEnvironment: ["HOME": "/Users/test", "PATH": "/tmp/attacker"]
        ))

        #expect(invocation.executable == "/opt/homebrew/bin/sshpass")
        #expect(invocation.arguments.prefix(4) == ["-e", "-v", "-P", "Pass phrase:"])
        #expect(invocation.arguments.contains("/usr/bin/ssh"))
        #expect(invocation.arguments.contains(
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/key").path
        ))
        #expect(invocation.arguments.suffix(2) == ["root@example.test", "sh -s"])
        #expect(invocation.environment["SSHPASS"] == "top secret")
        #expect(invocation.environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(!invocation.arguments.contains(where: { $0.contains("top secret") }))
        #expect(!invocation.arguments.contains("/tmp/attacker/ssh"))
    }

    @Test("Injected options stay options and hostile option vectors are refused")
    func canonicalOptionInsertionCannotBecomeDestinationOrRemotePayload() throws {
        let parsed = try #require(validator.validatedCommand("ssh -- root@example.test"))
        let invocation = try #require(parsed.invocation(
            injecting: ["-T", "-o", "ConnectTimeout=15"]
        ))
        #expect(invocation.arguments.suffix(5) == ["-o", "ConnectTimeout=15", "--", "root@example.test"])
        #expect(parsed.invocation(injecting: ["--", "-oProxyCommand=touch /tmp/pwn"]) == nil)
        #expect(parsed.invocation(injecting: ["-o", "ProxyCommand=touch /tmp/pwn"]) == nil)
        #expect(parsed.invocation(injecting: ["-R", "-oProxyCommand=bad"]) == nil)
    }
}
