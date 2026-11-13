import Foundation

/// One active pane per session from a bounded, socket-wide read. Ambiguous sessions are omitted.
struct UniConnectLocalTmuxPaneSnapshot: Equatable, Sendable {
    static let format = "#{session_name}\t#{pane_id}\t#{pane_pid}\t#{pane_dead}\t#{pane_current_path}\t#{pane_current_command}\t#{session_id}\t#{window_active}\t#{pane_active}"
    let sessionName: String
    let paneID: String
    let processID: Int
    let directory: String
    let command: String
    let sessionID: String

    static func parse(_ output: String) -> [String: Self] {
        guard output.utf8.count <= 4 * 1_024 * 1_024 else { return [:] }
        var result: [String: Self] = [:]
        var ambiguous = Set<String>()
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 9, fields[7] == "1", fields[8] == "1" else { continue }
            let name = fields[0]
            guard !ambiguous.contains(name) else { continue }
            guard fields[3] == "0", let pid = Int(fields[2]), pid > 1,
                  fields[1].hasPrefix("%"), Int(fields[1].dropFirst()) != nil,
                  fields[6].hasPrefix("$"), Int(fields[6].dropFirst()) != nil,
                  result[name] == nil else {
                result.removeValue(forKey: name)
                ambiguous.insert(name)
                continue
            }
            result[name] = Self(sessionName: name, paneID: fields[1], processID: pid,
                                directory: fields[4], command: fields[5], sessionID: fields[6])
        }
        return result
    }
}
