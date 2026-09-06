import Foundation

/// Removes only this attachment's bounded geometry frames, preserving arbitrary VT and UTF-8 bytes.
struct MobileTmuxOutputDecoder: Sendable {
    private let prefix: Data
    private var pending = Data()
    private let maximumFrameBytes = 128

    init(nonce: UUID) {
        let token = nonce.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        prefix = Data(("\u{001e}UCPTY_GEOMETRY_" + token + ":").utf8)
    }

    mutating func decode(_ output: MobilePTYOutput) -> [MobilePTYOutput] {
        guard case .bytes(let bytes) = output else {
            let remainder = pending
            pending = Data()
            return (remainder.isEmpty ? [] : [.bytes(remainder)]) + [output]
        }
        pending.append(bytes)
        var results: [MobilePTYOutput] = []
        while !pending.isEmpty {
            guard let match = pending.range(of: prefix) else {
                // A marker may span any read boundary. Hold only a possible prefix.
                var held = min(prefix.count - 1, pending.count)
                while held > 0 && pending.suffix(held) != prefix.prefix(held) { held -= 1 }
                let count = pending.count - held
                if count > 0 { results.append(.bytes(Data(pending.prefix(count)))) }
                pending = Data(pending.suffix(held))
                break
            }
            let preceding = pending.distance(from: pending.startIndex, to: match.lowerBound)
            if preceding > 0 { results.append(.bytes(Data(pending.prefix(preceding)))) }
            pending = Data(pending.dropFirst(preceding))
            if let end = pending.dropFirst(prefix.count).firstIndex(of: 0x1f),
               pending.distance(from: pending.startIndex, to: end) < maximumFrameBytes {
                let frameLength = pending.distance(from: pending.startIndex, to: end) + 1
                let fields = pending.dropFirst(prefix.count).prefix(frameLength - prefix.count - 1)
                if let text = String(data: fields, encoding: .ascii),
                   let geometry = MobileTmuxGeometry(fields: text[...]) {
                    results.append(.geometry(geometry))
                } else {
                    results.append(.bytes(Data(pending.prefix(frameLength))))
                }
                pending = Data(pending.dropFirst(frameLength))
            } else if pending.count >= maximumFrameBytes {
                // Invalid or unbounded candidates remain ordinary terminal bytes.
                results.append(.bytes(Data(pending.prefix(1))))
                pending = Data(pending.dropFirst())
            } else {
                break
            }
        }
        return results
    }
}
