import Foundation

/// Orden de `ffmpeg` que deja un clip cualquiera en lo único que whisper.cpp lee sin ayuda:
/// PCM de 16 bits, mono y 16 kHz.
///
/// La conversión va acotada en duración y en tamaño de salida. Sin esos topes, una hora de
/// audio comprimido en 3 MiB se expandiría a más de cien megas en el disco del equipo antes
/// de que nadie pudiera decir `too_large`.
struct MobileAudioConversionCommand: Equatable, Sendable {
    /// Bytes por segundo del formato de salida: 16 000 muestras de 2 bytes en un canal.
    static let outputBytesPerSecond = 32_000

    /// Clip de entrada.
    let input: URL
    /// WAV de salida.
    let output: URL
    /// Duración máxima admitida, en segundos.
    let maximumSeconds: Double

    /// - Parameters:
    ///   - input: Archivo temporal con el audio recibido.
    ///   - output: Archivo temporal donde se escribe el WAV convertido.
    ///   - maximumSeconds: Tope del contrato; la orden se corta un poco más allá para que un
    ///     clip que se pasa por poco se detecte al medirlo en vez de salir truncado sin más.
    init(input: URL, output: URL, maximumSeconds: Double) {
        self.input = input
        self.output = output
        self.maximumSeconds = maximumSeconds
    }

    /// Segundos que se dejan grabar, con el margen que delata al clip demasiado largo.
    var ceilingSeconds: Double {
        maximumSeconds + 10
    }

    /// Bytes máximos del WAV de salida, derivados del techo de duración.
    var ceilingBytes: Int {
        Int(ceilingSeconds * Double(Self.outputBytesPerSecond)) + 1_024
    }

    /// Argumentos de `ffmpeg`.
    ///
    /// `-nostdin` evita que el proceso se quede esperando en una entrada que nadie va a
    /// escribir, que es como un hijo suelto agota el presupuesto entero.
    var arguments: [String] {
        [
            "-nostdin",
            "-hide_banner",
            "-loglevel", "error",
            "-i", input.path,
            "-vn",
            "-map_metadata", "-1",
            "-ac", "1",
            "-ar", "16000",
            "-c:a", "pcm_s16le",
            "-t", String(format: "%.3f", ceilingSeconds),
            "-fs", String(ceilingBytes),
            "-y", output.path,
        ]
    }
}
