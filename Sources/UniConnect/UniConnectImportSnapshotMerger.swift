import Foundation

/// Reverts an import snapshot delta while retaining independently changed live fields.
enum UniConnectImportSnapshotMerger {
    enum MergeError: Error {
        case invalidSnapshotEncoding
    }

    /// Applies the inverse of `checkpoint -> imported` to `current` conditionally.
    ///
    /// A field is restored only while it still has the value written by the import.
    /// Concurrent values win. Arrays of windows, workspaces, panels, notifications,
    /// and groups are reconciled by their stable identifiers rather than by position.
    static func reverting(
        imported: AppSessionSnapshot,
        to checkpoint: AppSessionSnapshot,
        preserving current: AppSessionSnapshot
    ) throws -> AppSessionSnapshot {
        let checkpointObject = try jsonObject(for: checkpoint)
        let importedObject = try jsonObject(for: imported)
        let currentObject = try jsonObject(for: current)
        let merged = merge(
            checkpoint: checkpointObject,
            imported: importedObject,
            current: currentObject
        )
        guard JSONSerialization.isValidJSONObject(merged) else {
            throw MergeError.invalidSnapshotEncoding
        }
        let data = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
        return try JSONDecoder().decode(AppSessionSnapshot.self, from: data)
    }

    private static func jsonObject(for snapshot: AppSessionSnapshot) throws -> Any {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func merge(checkpoint: Any, imported: Any, current: Any) -> Any {
        if equal(checkpoint, imported) { return current }
        if equal(current, imported) { return checkpoint }

        if let checkpoint = checkpoint as? [String: Any],
           let imported = imported as? [String: Any],
           let current = current as? [String: Any] {
            return mergeObjects(checkpoint: checkpoint, imported: imported, current: current)
        }
        if let checkpoint = checkpoint as? [Any],
           let imported = imported as? [Any],
           let current = current as? [Any] {
            return mergeArrays(checkpoint: checkpoint, imported: imported, current: current)
        }
        // This field changed again after import. Preserve the concurrent value.
        return current
    }

    private static func mergeObjects(
        checkpoint: [String: Any],
        imported: [String: Any],
        current: [String: Any]
    ) -> [String: Any] {
        var result = current
        let keys = Set(checkpoint.keys).union(imported.keys)
        for key in keys {
            let before = checkpoint[key]
            let afterImport = imported[key]
            let now = current[key]
            switch (before, afterImport, now) {
            case (nil, let added?, let currentValue?):
                if equal(currentValue, added) { result.removeValue(forKey: key) }
            case (nil, _?, nil):
                break
            case (let removed?, nil, nil):
                result[key] = removed
            case (_?, nil, _?):
                // A caller recreated or replaced a value the import removed.
                break
            case (let before?, let imported?, let current?):
                result[key] = merge(
                    checkpoint: before,
                    imported: imported,
                    current: current
                )
            case (_?, _?, nil):
                // Deletion after the import is an overlapping external mutation.
                break
            case (nil, nil, _):
                break
            }
        }
        return result
    }

    private static func mergeArrays(
        checkpoint: [Any],
        imported: [Any],
        current: [Any]
    ) -> [Any] {
        if let key = stableIdentityKey(checkpoint: checkpoint, imported: imported, current: current) {
            return mergeIdentifiedArrays(
                checkpoint: checkpoint,
                imported: imported,
                current: current,
                key: key
            )
        }
        if isUUIDStringArray(checkpoint) || isUUIDStringArray(imported) || isUUIDStringArray(current) {
            return mergeUUIDArrays(checkpoint: checkpoint, imported: imported, current: current)
        }
        // Histories and other positional collections are atomic. Only restore them when
        // nobody changed the imported value, which was handled by the equality fast path.
        return current
    }

    private static func mergeIdentifiedArrays(
        checkpoint: [Any],
        imported: [Any],
        current: [Any],
        key: String
    ) -> [Any] {
        guard let before = identified(checkpoint, key: key),
              let afterImport = identified(imported, key: key),
              let now = identified(current, key: key) else {
            return current
        }
        var values = now.values
        var order = now.order

        for id in Set(before.values.keys).union(afterImport.values.keys) {
            let oldValue = before.values[id]
            let importedValue = afterImport.values[id]
            let currentValue = now.values[id]
            switch (oldValue, importedValue, currentValue) {
            case (nil, let added?, let currentValue?):
                if equal(currentValue, added) {
                    values.removeValue(forKey: id)
                    order.removeAll { $0 == id }
                }
            case (let removed?, nil, nil):
                values[id] = removed
                insert(id, using: before.order, into: &order)
            case (let oldValue?, let importedValue?, let currentValue?):
                values[id] = merge(
                    checkpoint: oldValue,
                    imported: importedValue,
                    current: currentValue
                )
            default:
                break
            }
        }

        if now.order == afterImport.order {
            let externalIDs = order.filter { !before.order.contains($0) }
            order = before.order.filter { values[$0] != nil } + externalIDs
        }
        return order.compactMap { values[$0] }
    }

    private static func mergeUUIDArrays(
        checkpoint: [Any],
        imported: [Any],
        current: [Any]
    ) -> [Any] {
        let before = checkpoint.compactMap { $0 as? String }
        let afterImport = imported.compactMap { $0 as? String }
        let now = current.compactMap { $0 as? String }
        guard before.count == checkpoint.count,
              afterImport.count == imported.count,
              now.count == current.count else {
            return current
        }
        let added = Set(afterImport).subtracting(before)
        let removed = Set(before).subtracting(afterImport)
        var result = now.filter { !added.contains($0) }
        for id in before where removed.contains(id) && !result.contains(id) {
            insert(id, using: before, into: &result)
        }
        return result
    }

    private static func stableIdentityKey(
        checkpoint: [Any],
        imported: [Any],
        current: [Any]
    ) -> String? {
        let populated = [checkpoint, imported, current].filter { !$0.isEmpty }
        guard !populated.isEmpty else { return nil }
        for key in ["windowId", "workspaceId", "id", "key"] {
            if populated.allSatisfy({ identified($0, key: key) != nil }) {
                return key
            }
        }
        return nil
    }

    private static func identified(
        _ values: [Any],
        key: String
    ) -> (order: [String], values: [String: Any])? {
        var order: [String] = []
        var result: [String: Any] = [:]
        for value in values {
            guard let object = value as? [String: Any],
                  let identity = object[key] as? String,
                  !identity.isEmpty,
                  result.updateValue(value, forKey: identity) == nil else {
                return nil
            }
            order.append(identity)
        }
        return (order, result)
    }

    private static func isUUIDStringArray(_ values: [Any]) -> Bool {
        !values.isEmpty && values.allSatisfy {
            guard let value = $0 as? String else { return false }
            return UUID(uuidString: value) != nil
        }
    }

    private static func insert(
        _ identity: String,
        using referenceOrder: [String],
        into order: inout [String]
    ) {
        guard !order.contains(identity) else { return }
        guard let referenceIndex = referenceOrder.firstIndex(of: identity) else {
            order.append(identity)
            return
        }
        if let successor = referenceOrder.dropFirst(referenceIndex + 1).first(where: order.contains),
           let insertionIndex = order.firstIndex(of: successor) {
            order.insert(identity, at: insertionIndex)
        } else {
            order.append(identity)
        }
    }

    private static func equal(_ lhs: Any, _ rhs: Any) -> Bool {
        switch (lhs, rhs) {
        case (let lhs as [String: Any], let rhs as [String: Any]):
            guard Set(lhs.keys) == Set(rhs.keys) else { return false }
            return lhs.allSatisfy { key, value in
                rhs[key].map { equal(value, $0) } == true
            }
        case (let lhs as [Any], let rhs as [Any]):
            return lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
                equal($0.0, $0.1)
            }
        case (let lhs as NSNumber, let rhs as NSNumber):
            return lhs == rhs && String(cString: lhs.objCType) == String(cString: rhs.objCType)
        case (let lhs as NSString, let rhs as NSString):
            return lhs == rhs
        case (_ as NSNull, _ as NSNull):
            return true
        default:
            return false
        }
    }
}
