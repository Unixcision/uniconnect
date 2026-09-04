import Foundation

/// Parses workspace arrays lossily so one malformed JSON declaration remains visible in preview.
enum UniConnectJSONImportParser {
    static func parseDetailed(_ data: Data) throws -> UniConnectImportSourceDocument {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any],
              let rawWorkspaces = root["workspaces"] as? [Any] else {
            throw UniConnectError.corruptFile("el JSON no contiene un array workspaces")
        }
        let version = root["version"] as? Int ?? 1
        guard version >= 1, version <= UniConnectDocument.currentVersion else {
            throw UniConnectError.corruptFile(String(
                format: String(
                    localized: "uniconnect.jsonImport.error.unsupportedDocumentVersion",
                    defaultValue: "unsupported document version: %d"
                ),
                version
            ))
        }

        var workspaces: [UniConnectDocument.Workspace] = []
        var sourceMap = UniConnectImportSourceMap()
        workspaces.reserveCapacity(rawWorkspaces.count)

        for (workspaceIndex, rawWorkspace) in rawWorkspaces.enumerated() {
            let section = "workspaces[\(workspaceIndex)]"
            let location = UniConnectImportSourceLocation(line: 1, section: section)
            sourceMap.workspaceLocations[workspaceIndex] = location
            guard let dictionary = rawWorkspace as? [String: Any] else {
                workspaces.append(invalidWorkspace())
                sourceMap.diagnosticsByWorkspace[workspaceIndex] = [diagnostic(
                    code: .malformedJSONWorkspace,
                    location: location,
                    subject: nil
                )]
                continue
            }

            if let decoded = decode(UniConnectDocument.Workspace.self, object: dictionary) {
                workspaces.append(decoded)
                addWindowLocations(
                    count: decoded.windows.count,
                    workspaceIndex: workspaceIndex,
                    section: section,
                    to: &sourceMap
                )
                continue
            }

            var workspaceDiagnostics = [diagnostic(
                code: .malformedJSONWorkspace,
                location: location,
                subject: string(dictionary["name"])
            )]
            let kind = UniConnectWorkspaceKind(rawValue: string(dictionary["kind"]) ?? "") ?? .local
            let rawWindows = dictionary["windows"] as? [Any] ?? []
            var windows: [UniConnectDocument.Window] = []
            for (windowIndex, rawWindow) in rawWindows.enumerated() {
                let windowSection = "\(section).windows[\(windowIndex)]"
                let windowLocation = UniConnectImportSourceLocation(line: 1, section: windowSection)
                let key = UniConnectImportSourceMap.WindowKey(
                    workspaceIndex: workspaceIndex,
                    windowIndex: windowIndex
                )
                sourceMap.windowLocations[key] = windowLocation
                if let dictionary = rawWindow as? [String: Any],
                   let decoded = decode(UniConnectDocument.Window.self, object: dictionary) {
                    windows.append(decoded)
                } else {
                    let dictionary = rawWindow as? [String: Any] ?? [:]
                    windows.append(.init(
                        name: string(dictionary["name"]),
                        tmux: string(dictionary["tmux"]),
                        claudeSession: string(dictionary["claudeSession"]),
                        cwd: string(dictionary["cwd"]),
                        isPinned: boolean(dictionary["isPinned"])
                    ))
                    sourceMap.diagnosticsByWindow[key] = [diagnostic(
                        code: .malformedJSONWindow,
                        location: windowLocation,
                        subject: string(dictionary["name"])
                    )]
                }
            }
            if dictionary["windows"] != nil, dictionary["windows"] as? [Any] == nil {
                workspaceDiagnostics.append(diagnostic(
                    code: .malformedJSONWorkspace,
                    location: location,
                    subject: string(dictionary["name"])
                ))
            }
            sourceMap.diagnosticsByWorkspace[workspaceIndex] = workspaceDiagnostics
            workspaces.append(.init(
                id: string(dictionary["id"]).flatMap(UUID.init(uuidString:)),
                name: string(dictionary["name"]) ?? "",
                kind: kind,
                color: string(dictionary["color"]),
                group: string(dictionary["group"]),
                isPinned: boolean(dictionary["isPinned"]),
                cwd: string(dictionary["cwd"]),
                connect: string(dictionary["connect"]),
                windows: windows
            ))
        }

        return UniConnectImportSourceDocument(
            document: UniConnectDocument(workspaces: workspaces),
            sourceMap: sourceMap
        )
    }

    private static func addWindowLocations(
        count: Int,
        workspaceIndex: Int,
        section: String,
        to sourceMap: inout UniConnectImportSourceMap
    ) {
        for windowIndex in 0..<count {
            sourceMap.windowLocations[.init(
                workspaceIndex: workspaceIndex,
                windowIndex: windowIndex
            )] = .init(line: 1, section: "\(section).windows[\(windowIndex)]")
        }
    }

    private static func invalidWorkspace() -> UniConnectDocument.Workspace {
        .init(
            name: "",
            kind: .local,
            color: nil,
            group: nil,
            isPinned: nil,
            cwd: nil,
            connect: nil,
            windows: []
        )
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        object: Any
    ) -> Value? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    private static func boolean(_ value: Any?) -> Bool? {
        value as? Bool
    }

    private static func diagnostic(
        code: UniConnectImportDiagnostic.Code,
        location: UniConnectImportSourceLocation,
        subject: String?
    ) -> UniConnectImportDiagnostic {
        .init(severity: .error, code: code, location: location, subject: subject)
    }
}
