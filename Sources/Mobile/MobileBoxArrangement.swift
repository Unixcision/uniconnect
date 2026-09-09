import Foundation

/// Semántica de favoritos y orden del contrato `box_update` (docs/UNICONNECT.md).
///
/// Es una proyección pura: recibe el orden actual y el conjunto de fijados, aplica primero
/// `is_pinned` (valor explícito, nunca toggle) y después `position`, base cero DENTRO de
/// su grupo (fijados / no fijados) y recortada al rango, y devuelve el orden resultante
/// con los fijados primero y estable para el resto. Nunca decide sobre foco, selección ni
/// splits: eso lo respeta quien aplica el plan. Al quitar el favorito, el elemento se
/// queda donde está en la lista única (delante de los no fijados), como en Linux.
struct MobileBoxArrangement<ID: Hashable>: Equatable {
    /// Orden completo resultante: fijados primero, estable dentro de cada grupo.
    let orderedIDs: [ID]
    /// Conjunto de fijados tras aplicar el cambio.
    let pinnedIDs: Set<ID>

    init(orderedIDs: [ID], pinnedIDs: Set<ID>) {
        self.orderedIDs = orderedIDs
        self.pinnedIDs = pinnedIDs
    }

    /// Proyección del orden actual con los fijados primero, sin mutar nada.
    static func pinnedFirst(_ orderedIDs: [ID], pinnedIDs: Set<ID>) -> [ID] {
        orderedIDs.filter { pinnedIDs.contains($0) } + orderedIDs.filter { !pinnedIDs.contains($0) }
    }

    /// Plan para `target`; `nil` si no está en la lista.
    ///
    /// - Parameters:
    ///   - orderedIDs: Orden actual del host (la lista única).
    ///   - pinnedIDs: Fijados actuales.
    ///   - target: Elemento que cambia.
    ///   - isPinned: Nuevo valor del favorito, o `nil` para no tocarlo.
    ///   - position: Posición base cero dentro de su grupo, o `nil` para no moverlo.
    static func plan(
        orderedIDs: [ID],
        pinnedIDs: Set<ID>,
        target: ID,
        isPinned: Bool?,
        position: Int?
    ) -> MobileBoxArrangement? {
        guard orderedIDs.contains(target) else { return nil }
        var pinned = pinnedIDs.intersection(orderedIDs)
        if let isPinned {
            if isPinned {
                pinned.insert(target)
            } else {
                pinned.remove(target)
            }
        }
        var ordered = pinnedFirst(orderedIDs, pinnedIDs: pinned)
        if let position {
            let targetIsPinned = pinned.contains(target)
            var group = ordered.filter { pinned.contains($0) == targetIsPinned && $0 != target }
            group.insert(target, at: max(0, min(position, group.count)))
            let others = ordered.filter { pinned.contains($0) != targetIsPinned }
            ordered = targetIsPinned ? group + others : others + group
        }
        return MobileBoxArrangement(orderedIDs: ordered, pinnedIDs: pinned)
    }

    /// Índice global de `id` en el orden resultante.
    func index(of id: ID) -> Int? {
        orderedIDs.firstIndex(of: id)
    }
}
