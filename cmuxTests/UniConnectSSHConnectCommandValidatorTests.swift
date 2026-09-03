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
            "/opt/homebrew/bin/sshpass -psecret /usr/bin/ssh -v root@[2001:db8::1]",
            "ssh -- host-alias",
        ]

        for command in commands {
            #expect(validator.validate(command) == nil, "Expected supported command: \(command)")
        }
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
    }

    @Test("Remote commands and SSH options capable of local execution are rejected")
    func rejectsUnsafeSSHPayloads() {
        #expect(validator.validate("ssh root@host 'uname -a'") == .remoteCommand)
        #expect(validator.validate("ssh root@host -- harmless") == .remoteCommand)
        #expect(validator.validate("ssh -o ProxyCommand='sh -c whoami' root@host") == .unsafeSSHOption)
        #expect(validator.validate("ssh -oLocalCommand=whoami root@host") == .unsafeSSHOption)
        #expect(validator.validate("ssh -F /tmp/ssh_config root@host") == .unsafeSSHOption)
        #expect(validator.validate("ssh -L 8080:localhost:80 root@host") == .unsafeSSHOption)
        #expect(validator.validate("ssh -N root@host") == .unsafeSSHOption)
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
}
