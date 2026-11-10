import Foundation

/// The `KERN_PROCARGS2` buffer of a process, decoded into its real argv and environment.
///
/// Layout: `argc` (Int32), the executable path, NUL padding, then exactly `argc` NUL-terminated
/// arguments (an empty argument is a single NUL), then the environment. Empty arguments are kept:
/// dropping them would shift every value after them onto the wrong option.
struct UniConnectRelaunchProcArgs: Sendable, Equatable {
    let argv: [String]
    let environment: [String: String]

    init?(bytes: [UInt8]) {
        guard bytes.count > 4 else { return nil }
        let argc = Int(Int32(littleEndian: bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }))
        guard argc > 0, argc < 4_096 else { return nil }
        var index = 4
        while index < bytes.count, bytes[index] != 0 { index += 1 }   // executable path
        while index < bytes.count, bytes[index] == 0 { index += 1 }   // padding
        var argv: [String] = []
        for _ in 0..<argc {
            guard index < bytes.count else { return nil }
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            argv.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        var environment: [String: String] = [:]
        while index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            if index > start {
                let entry = String(decoding: bytes[start..<index], as: UTF8.self)
                if let equals = entry.firstIndex(of: "="), equals != entry.startIndex {
                    environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
                }
            } else if index == start, !environment.isEmpty || index + 1 >= bytes.count {
                // Two NULs in a row after the environment: the rest is the kernel's apple strings.
                break
            }
            index += 1
        }
        self.argv = argv
        self.environment = environment
    }
}
