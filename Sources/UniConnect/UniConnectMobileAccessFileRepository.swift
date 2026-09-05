import CMUXMobileCore
import Foundation

/// Owns one private file of locally approved Tailscale peer addresses.
actor UniConnectMobileAccessFileRepository: UniConnectMobileAccessRepository {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() throws -> [UniConnectMobileApprovedPeer] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? Int.max) <= 128 * 1024 else { throw StorageError.invalidFile }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: fileURL))
        guard document.version == 1, document.peers.count <= 128 else { throw StorageError.invalidFile }
        var addresses = Set<String>()
        for peer in document.peers {
            guard TailnetPeerAddress(peer.address)?.rawValue == peer.address,
                  addresses.insert(peer.address).inserted, peer.label.count <= 80 else {
                throw StorageError.invalidFile
            }
        }
        return document.peers
    }

    func save(_ peers: [UniConnectMobileApprovedPeer]) throws {
        guard peers.count <= 128 else { throw StorageError.invalidFile }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let directoryValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else {
            throw StorageError.invalidFile
        }
        // The composition root supplies a dedicated approvals directory, not a
        // shared application-support root. Atomic replacement stays inside it.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try JSONEncoder().encode(Document(version: 1, peers: peers))
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private struct Document: Codable {
        let version: Int
        let peers: [UniConnectMobileApprovedPeer]
    }

    private enum StorageError: Error { case invalidFile }
}
