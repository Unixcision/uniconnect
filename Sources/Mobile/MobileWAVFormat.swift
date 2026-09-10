import Foundation

/// Cabecera RIFF/WAVE leída del propio audio.
///
/// Es la fuente autorizada de la duración cuando el clip ya es WAV: se recorren los trozos
/// (`fmt `, `data`, …) en vez de confiar en el MIME o en las posiciones fijas, porque un
/// grabador puede intercalar `LIST` o `fact` antes de los datos.
struct MobileWAVFormat: Equatable, Sendable {
    /// Muestras por segundo.
    let sampleRate: Int
    /// Canales (1 = mono).
    let channels: Int
    /// Bits por muestra.
    let bitsPerSample: Int
    /// Bytes reales de muestras, ya acotados a lo que el archivo contiene.
    let dataBytes: Int

    /// Duración en segundos derivada del propio bloque de datos.
    var seconds: Double {
        let bytesPerFrame = channels * max(bitsPerSample, 1) / 8
        guard sampleRate > 0, bytesPerFrame > 0 else { return 0 }
        return Double(dataBytes) / Double(bytesPerFrame * sampleRate)
    }

    /// PCM 16 bits, mono y 16 kHz: lo único que whisper.cpp lee sin pasar por `ffmpeg`.
    var isWhisperReady: Bool {
        sampleRate == 16_000 && channels == 1 && bitsPerSample == 16
    }

    /// Lee la cabecera de un WAV PCM.
    ///
    /// - Parameter data: Clip completo tal y como llegó del móvil.
    /// - Returns: La cabecera, o `nil` si no es un WAV PCM legible.
    static func parse(_ data: Data) -> MobileWAVFormat? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12,
              Self.tag(bytes, at: 0) == "RIFF",
              Self.tag(bytes, at: 8) == "WAVE" else {
            return nil
        }
        var offset = 12
        var audioFormat: Int?
        var channels: Int?
        var sampleRate: Int?
        var bitsPerSample: Int?
        var dataBytes: Int?
        while offset + 8 <= bytes.count {
            let id = Self.tag(bytes, at: offset)
            let declared = Int(Self.uint32(bytes, at: offset + 4))
            let body = offset + 8
            let available = max(0, bytes.count - body)
            let size = min(declared, available)
            switch id {
            case "fmt ":
                guard size >= 16 else { return nil }
                audioFormat = Int(Self.uint16(bytes, at: body))
                channels = Int(Self.uint16(bytes, at: body + 2))
                sampleRate = Int(Self.uint32(bytes, at: body + 4))
                bitsPerSample = Int(Self.uint16(bytes, at: body + 14))
            case "data":
                dataBytes = size
            default:
                break
            }
            // Los trozos RIFF se alinean a par; un tamaño declarado imposible corta el recorrido.
            guard declared >= 0, declared <= available || id == "data" else { return nil }
            offset = body + size + (size % 2)
            if dataBytes != nil, channels != nil { break }
        }
        guard let audioFormat, audioFormat == 1,
              let channels, channels > 0,
              let sampleRate, sampleRate > 0,
              let bitsPerSample, bitsPerSample > 0,
              let dataBytes else {
            return nil
        }
        return MobileWAVFormat(
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample,
            dataBytes: dataBytes
        )
    }

    private static func tag(_ bytes: [UInt8], at offset: Int) -> String {
        guard offset + 4 <= bytes.count else { return "" }
        return String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
    }

    private static func uint16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        guard offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
