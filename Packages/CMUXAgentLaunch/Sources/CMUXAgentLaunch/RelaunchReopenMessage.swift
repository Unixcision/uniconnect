import Foundation

/// The exact text typed into an agent after it is reopened, and when it is typed at all.
///
/// Reopening costs nothing; the message is what costs quota, because it makes the agent reread
/// its whole conversation, without cache if the model changed. On 09-11-2026 that ate 37 % of a
/// Fable plan. So a message goes only to an agent that had monitors or shells in the background,
/// or that was working when it was closed; any other agent gets nothing typed into it.
///
/// The texts are `contracts/relaunch-v1/mensajes.json`, the same on the Mac and on Linux. They are
/// carried here as constants and a contract test compares them with that file byte for byte.
///
/// ```swift
/// let message = RelaunchReopenMessage(
///     reason: .update(version: "2.1.321"),
///     monitors: 3,
///     monitorsFile: "/root/.local/state/uniconnect/relaunch-v1/monitores/57c8-20261109-221500.txt",
///     wasWorking: false
/// )
/// message?.text  // "UniConnect te ha reiniciado para actualizar Claude Code a 2.1.321. Al cerrar…"
/// ```
public struct RelaunchReopenMessage: Sendable, Equatable {
    /// Why the agent was restarted, which names the verb in the text.
    public enum Reason: Sendable, Equatable {
        /// `agent.relaunch`.
        case relaunch
        /// `agent.update`, with the version it was updated to.
        case update(version: String)
    }

    /// `mensajes.json` → `motivo_actualizar`.
    static let updateReason = "para actualizar Claude Code a {version}"
    /// `mensajes.json` → `motivo_relanzar`.
    static let relaunchReason = "para relanzarte"
    /// `mensajes.json` → `con_monitores`.
    static let withMonitors = "UniConnect te ha reiniciado {motivo}. Al cerrar se pararon tus {n} monitores o shells de fondo; están guardados tal cual en {fichero}. Relanza una sola vez, igual que estaban, los que sean vigías o monitores de espera (si alguno ya no tiene sentido, dilo en vez de relanzarlo). Los que eran acciones puntuales (envíos, publicaciones, despliegues, migraciones) NO los repitas: comprueba en qué estado quedaron y dilo. Luego sigue con lo que estabas haciendo."
    /// `mensajes.json` → `solo_cortado`.
    static let onlyInterrupted = "UniConnect te ha reiniciado {motivo} mientras trabajabas, así que lo que tenías en marcha se cortó a medias. Retómalo justo donde se quedó."
    /// `mensajes.json` → `anadido_cortado`.
    static let interruptedSuffix = " Estabas trabajando cuando se te reinició, así que lo que tenías en marcha se cortó a medias: retómalo justo donde se quedó."

    /// The text to type, then submit with return.
    public let text: String

    /// The message for an agent, or `nil` when nothing should be typed into it.
    ///
    /// - Parameters:
    ///   - reason: Why it was restarted.
    ///   - monitors: How many monitors or background shells were saved and stopped.
    ///   - monitorsFile: Where they were saved on the destination; required when `monitors > 0`.
    ///   - wasWorking: Whether it was in the middle of a turn when it was closed.
    public init?(reason: Reason, monitors: Int, monitorsFile: String?, wasWorking: Bool) {
        let motive: String
        switch reason {
        case .relaunch:
            motive = Self.relaunchReason
        case let .update(version):
            motive = Self.updateReason.replacingOccurrences(of: "{version}", with: version)
        }
        if monitors > 0, let monitorsFile {
            var text = Self.withMonitors
                .replacingOccurrences(of: "{motivo}", with: motive)
                .replacingOccurrences(of: "{n}", with: String(monitors))
                .replacingOccurrences(of: "{fichero}", with: monitorsFile)
            if wasWorking { text += Self.interruptedSuffix }
            self.text = text
        } else if wasWorking {
            self.text = Self.onlyInterrupted.replacingOccurrences(of: "{motivo}", with: motive)
        } else {
            return nil
        }
    }

    /// Whether an agent with these traits gets a message, decided before anything is closed.
    ///
    /// - Parameters:
    ///   - monitors: Its background monitors and shells.
    ///   - wasWorking: Whether it is in the middle of a turn.
    /// - Returns: `true` exactly when ``init(reason:monitors:monitorsFile:wasWorking:)`` would
    ///   produce a message.
    public static func isNeeded(monitors: Int, wasWorking: Bool) -> Bool {
        monitors > 0 || wasWorking
    }
}
