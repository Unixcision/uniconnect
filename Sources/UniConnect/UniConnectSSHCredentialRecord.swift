import Foundation

/// One encrypted SSH credential revision and the endpoint it was resolved to use.
struct UniConnectSSHCredentialRecord: Codable, Equatable, Hashable, Sendable {
    let connectCommand: String
    let effectiveTarget: UniConnectSSHEffectiveTarget?

    init(
        connectCommand: String,
        effectiveTarget: UniConnectSSHEffectiveTarget?
    ) {
        self.connectCommand = connectCommand
        self.effectiveTarget = effectiveTarget
    }

    private enum CodingKeys: String, CodingKey {
        case connectCommand
        case effectiveTarget
    }

    private enum EffectiveTargetCodingKeys: String, CodingKey {
        case user
        case host
        case port
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        connectCommand = try container.decode(String.self, forKey: .connectCommand)
        guard container.contains(.effectiveTarget) else {
            effectiveTarget = nil
            return
        }
        if try container.decodeNil(forKey: .effectiveTarget) {
            effectiveTarget = nil
            return
        }

        let targetContainer = try container.nestedContainer(
            keyedBy: EffectiveTargetCodingKeys.self,
            forKey: .effectiveTarget
        )
        let user = try targetContainer.decode(String.self, forKey: .user)
        let host = try targetContainer.decode(String.self, forKey: .host)
        let port = try targetContainer.decode(Int.self, forKey: .port)
        guard let target = UniConnectSSHEffectiveTarget(user: user, host: host, port: port) else {
            throw DecodingError.dataCorruptedError(
                forKey: .effectiveTarget,
                in: container,
                debugDescription: "Invalid encrypted SSH effective target"
            )
        }
        effectiveTarget = target
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(connectCommand, forKey: .connectCommand)
        guard let effectiveTarget else { return }

        var targetContainer = container.nestedContainer(
            keyedBy: EffectiveTargetCodingKeys.self,
            forKey: .effectiveTarget
        )
        try targetContainer.encode(effectiveTarget.user, forKey: .user)
        try targetContainer.encode(effectiveTarget.host, forKey: .host)
        try targetContainer.encode(effectiveTarget.port, forKey: .port)
    }
}
