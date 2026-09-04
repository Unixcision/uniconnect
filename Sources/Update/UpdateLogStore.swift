import Foundation
import AppKit
import CmuxUpdater

// @unchecked Sendable: all mutable state (`entries`) is confined to the serial `queue`; the
// other stored properties are immutable. Conforms to CmuxUpdater's `UpdateLogging` seam so the
// updater package can log through this app-owned file logger.
final class UpdateLogStore: UpdateLogging, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.unixcision.uniconnect.update.log")
    private var entries: [String] = []
    private let maxEntries = 200
    private let logURL: URL
    private let formatter: ISO8601DateFormatter

    init() {
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stateDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".uniconnect", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        logURL = stateDirectory.appendingPathComponent("update.log", isDirectory: false)
        ensureLogFile()
    }

    func append(_ message: String) {
        let timestamp = formatter.string(from: Date())
        let bundle = Bundle.main.bundleIdentifier ?? "<no.bundle.id>"
        let pid = ProcessInfo.processInfo.processIdentifier
        let line = "[\(timestamp)] [\(bundle):\(pid)] \(message)"
        queue.async { [weak self] in
            guard let self else { return }
            entries.append(line)
            if entries.count > maxEntries {
                entries.removeFirst(entries.count - maxEntries)
            }
            appendToFile(line: line)
        }
    }

    func snapshot() -> String {
        queue.sync {
            entries.joined(separator: "\n")
        }
    }

    func logPath() -> String {
        logURL.path
    }

    private func ensureLogFile() {
        let directory = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            try? Data().write(to: logURL)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
    }

    private func appendToFile(line: String) {
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }
}

// @unchecked Sendable: all mutable state (`entries`) is confined to the serial `queue`; the other
// stored properties are immutable. Owned and injected by `AppDelegate` (see `AppDelegate.focusLog`)
// rather than self-vending a global, so its lifecycle has a single composition root.
final class FocusLogStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.unixcision.uniconnect.focus.log")
    private var entries: [String] = []
    private let maxEntries = 400
    private let logURL: URL
    private let formatter: ISO8601DateFormatter

    init() {
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stateDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".uniconnect", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        logURL = stateDirectory.appendingPathComponent("focus.log", isDirectory: false)
        ensureLogFile()
    }

    func append(_ message: String) {
        #if DEBUG
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] \(message)"
        queue.async { [weak self] in
            guard let self else { return }
            entries.append(line)
            if entries.count > maxEntries {
                entries.removeFirst(entries.count - maxEntries)
            }
            appendToFile(line: line)
        }
        #endif
    }

    func snapshot() -> String {
        queue.sync {
            entries.joined(separator: "\n")
        }
    }

    func logPath() -> String {
        logURL.path
    }

    private func ensureLogFile() {
        let directory = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            try? Data().write(to: logURL)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
    }

    private func appendToFile(line: String) {
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }
}
