import Foundation
import Testing

@Suite struct CLIControlSocketIsolationTests {
    private final class BundleProbe {}

    private struct ProcessResult {
        let status: Int32
        let standardError: String
    }

    private enum TestError: Error {
        case bundledCLINotFound
        case processTimedOut
    }

    @Test(arguments: [false, true])
    func rejectsForeignCmuxSocketFromEnvironmentAndFlag(useExplicitFlag: Bool) throws {
        let socketPath = "/tmp/cmux-debug-foreign-\(UUID().uuidString).sock"
        var environment = isolatedEnvironment()
        let arguments: [String]
        if useExplicitFlag {
            arguments = ["--socket", socketPath, "ping"]
        } else {
            environment["CMUX_SOCKET_PATH"] = socketPath
            arguments = ["ping"]
        }

        let result = try runCLI(arguments: arguments, environment: environment)

        #expect(result.status == 1)
        #expect(result.standardError.contains("UNICONNECT_ALLOW_FOREIGN_SOCKET=1"))
        #expect(!result.standardError.contains(socketPath))
    }

    @Test func rejectsSocketInheritedFromForeignBundleContext() throws {
        var environment = isolatedEnvironment()
        environment["CMUX_BUNDLE_ID"] = "com.cmuxterm.app"
        environment["CMUX_SOCKET_PATH"] = "/tmp/uniconnect-debug-inherited.sock"

        let result = try runCLI(arguments: ["ping"], environment: environment)

        #expect(result.status == 1)
        #expect(result.standardError.contains("UNICONNECT_ALLOW_FOREIGN_SOCKET=1"))
        #expect(!result.standardError.contains("/tmp/uniconnect-debug-inherited.sock"))
    }

    @Test func deliberateOneCommandOptInReachesNormalSocketValidation() throws {
        let socketPath = "/tmp/cmux-debug-deliberate-\(UUID().uuidString).sock"
        var environment = isolatedEnvironment()
        environment["UNICONNECT_ALLOW_FOREIGN_SOCKET"] = "1"

        let result = try runCLI(
            arguments: ["--socket", socketPath, "ping"],
            environment: environment
        )

        #expect(result.status == 1)
        #expect(result.standardError.contains("Socket not found"))
        #expect(result.standardError.contains(socketPath))
        #expect(!result.standardError.contains("UNICONNECT_ALLOW_FOREIGN_SOCKET=1"))
    }

    private func isolatedEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys)
        where key.hasPrefix("CMUX_") || key.hasPrefix("UNICONNECT_") {
            environment.removeValue(forKey: key)
        }
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return environment
    }

    private func runCLI(arguments: [String], environment: [String: String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = try bundledCLIURL()
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice

        let standardErrorPipe = Pipe()
        process.standardError = standardErrorPipe
        try process.run()

        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard !process.isRunning else {
            process.terminate()
            process.waitUntilExit()
            throw TestError.processTimedOut
        }
        process.waitUntilExit()

        let errorData = standardErrorPipe.fileHandleForReading.readDataToEndOfFile()
        return ProcessResult(
            status: process.terminationStatus,
            standardError: String(decoding: errorData, as: UTF8.self)
        )
    }

    private func bundledCLIURL() throws -> URL {
        let appBundleURL = Bundle(for: BundleProbe.self)
            .bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let enumerator = FileManager.default.enumerator(
            at: appBundleURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        while let item = enumerator?.nextObject() as? URL {
            let supportedNames = ["uniconnect", "cmux"]
            guard supportedNames.contains(item.lastPathComponent),
                  item.path.contains(".app/Contents/Resources/bin/") else {
                continue
            }
            return item
        }

        throw TestError.bundledCLINotFound
    }
}
