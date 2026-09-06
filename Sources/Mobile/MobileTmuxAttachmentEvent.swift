import Foundation

/// One ordered PTY event addressed exclusively to the connection that owns its attachment.
struct MobileTmuxAttachmentEvent: Sendable {
    let attachID: UUID
    let workspaceID: UUID
    let surfaceID: UUID
    let sequence: UInt64
    let output: MobilePTYOutput

    var jsonObject: [String: Any] {
        var payload: [String: Any] = [
            "attach_id": attachID.uuidString,
            "workspace_id": workspaceID.uuidString,
            "surface_id": surfaceID.uuidString,
            "seq": sequence,
        ]
        switch output {
        case .bytes(let data):
            payload["data"] = data.base64EncodedString()
        case .geometry(let geometry):
            payload.merge(geometry.jsonObject) { _, value in value }
        case .exited(let status):
            payload["exit"] = true
            payload["exit_code"] = status
            if status != 0 { payload["error"] = "attach_failed" }
        case .failed:
            payload["exit"] = true
            payload["error"] = "pty_io_failed"
        }
        return payload
    }
}
