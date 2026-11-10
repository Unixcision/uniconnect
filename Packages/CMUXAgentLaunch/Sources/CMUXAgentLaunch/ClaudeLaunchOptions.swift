import Foundation

/// The options a live Claude ran with that come back when it is reopened, and the ones that do not.
///
/// Relaunching gives back the **same** agent (`contracts/relaunch-v1`, «Mismas opciones»,
/// 08-11-2026): every allowlisted option of the live process returns in the order it ran with;
/// anything else is left out and reported by name only, never with its value. The conversation
/// selector (`--resume`, `-r`, `--session-id`, `--continue`, `-c`) is replaced by the proven one.
///
/// The list is `launchOptions` of Claude in `agent-resume-v1.json`, the catalogue both platforms
/// read; `--effort` is on it since 09-11 (every Claude on the Mac carries `--effort medium`, and
/// dropping it would bring the agent back with another effort). If the catalogue cannot be read,
/// the same list built in here applies.
///
/// ```swift
/// let options = ClaudeLaunchOptions(argv: ["claude", "--resume", "old", "--model", "opus[1m]", "-p", "hola"])
/// options.kept     // ["--model", "opus[1m]"]
/// options.dropped  // ["-p"]
/// options.resumeArgv(launcher: "claude", conversation: "57c8…")
/// // ["claude", "--resume", "57c8…", "--model", "opus[1m]"]
/// ```
public struct ClaudeLaunchOptions: Sendable, Equatable {
    /// Which options come back: those carrying one value, and the switches that stand alone.
    public struct Allowlist: Sendable, Equatable {
        /// Options that carry one value, as the next argument or as `--option=value`.
        public let values: Set<String>
        /// Options that stand alone.
        public let switches: Set<String>

        /// Creates an allowlist.
        ///
        /// - Parameters:
        ///   - values: Options that carry one value.
        ///   - switches: Options that stand alone.
        public init(values: Set<String>, switches: Set<String>) {
            self.values = values
            self.switches = switches
        }

        /// The list built in here, the same the catalogue carries, for when it cannot be read.
        public static let builtIn = Allowlist(
            values: [
                "--model", "--effort", "--fallback-model", "--permission-mode", "--settings", "--setting-sources",
                "--add-dir", "--allowedTools", "--disallowedTools", "--mcp-config", "--tools",
            ],
            switches: [
                "--dangerously-skip-permissions", "--allow-dangerously-skip-permissions", "--verbose",
                "--strict-mcp-config", "--chrome",
            ]
        )

        /// Claude's `launchOptions` from the bundled `agent-resume-v1.json`, or ``builtIn``.
        public static let catalogue: Allowlist = {
            guard let options = (try? AgentResumeCatalog())?.providers["claude"]?.launchOptions else { return .builtIn }
            return Allowlist(values: Set(options.values), switches: Set(options.switches))
        }()
    }

    /// Options that carry one value, from the catalogue.
    public static var valueOptions: Set<String> { Allowlist.catalogue.values }
    /// Options that stand alone, from the catalogue.
    public static var switches: Set<String> { Allowlist.catalogue.switches }

    /// The kept arguments, in the order the process had them.
    public let kept: [String]
    /// Names of the options left out (`<posicional>` for a bare word), in order.
    public let dropped: [String]

    /// Filters a live Claude's argv.
    ///
    /// - Parameters:
    ///   - argv: The process's real arguments, executable first.
    ///   - allowlist: What comes back; the catalogue's by default.
    public init(argv: [String], allowlist: Allowlist = .catalogue) {
        let arguments = Array(argv.dropFirst())
        var kept: [String] = []
        var dropped: [String] = []
        var index = 0
        func hasValue(after position: Int) -> Bool {
            position + 1 < arguments.count && !arguments[position + 1].hasPrefix("-")
        }
        while index < arguments.count {
            let argument = arguments[index]
            if ["--resume", "-r", "--session-id"].contains(argument) {
                index += hasValue(after: index) ? 2 : 1
                continue
            }
            if argument.hasPrefix("--resume=") || argument.hasPrefix("--session-id=")
                || ["--continue", "-c", "--last", "--all"].contains(argument) {
                index += 1
                continue
            }
            let option = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
            if allowlist.values.contains(option) {
                if argument.contains("=") {
                    kept.append(argument)
                    index += 1
                } else if index + 1 < arguments.count {
                    kept += [argument, arguments[index + 1]]
                    index += 2
                } else {
                    dropped.append(option)
                    index += 1
                }
                continue
            }
            if allowlist.switches.contains(argument) {
                kept.append(argument)
                index += 1
                continue
            }
            // Left out, and its value with it: a value must never come back as a prompt.
            dropped.append(argument.hasPrefix("-") ? option : "<posicional>")
            index += (argument.hasPrefix("-") && !argument.contains("=") && hasValue(after: index)) ? 2 : 1
        }
        self.kept = kept
        self.dropped = dropped
    }

    private init(kept: [String], dropped: [String]) {
        self.kept = kept
        self.dropped = dropped
    }

    /// The same options with `update`'s model and effort in place of the ones it had.
    ///
    /// - Parameter update: What `agent.update` asked for; an absent value keeps the current one.
    /// - Returns: The options with `--model` and/or `--effort` replaced, appended at the end.
    public func applying(_ update: RelaunchUpdateOptions) -> ClaudeLaunchOptions {
        guard !update.isUnchanged else { return self }
        var removed: Set<String> = []
        if update.model != nil { removed.insert("--model") }
        if update.effort != nil { removed.insert("--effort") }
        var result: [String] = []
        var index = 0
        while index < kept.count {
            let argument = kept[index]
            let option = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
            if removed.contains(option) {
                index += argument.contains("=") ? 1 : 2
                continue
            }
            result.append(argument)
            if Self.valueOptions.contains(option), !argument.contains("="), index + 1 < kept.count {
                result.append(kept[index + 1])
                index += 1
            }
            index += 1
        }
        return ClaudeLaunchOptions(kept: result + update.arguments, dropped: dropped)
    }

    /// The value of `option` among the kept arguments (the last one when it repeats).
    ///
    /// - Parameter option: `--model`, `--effort`…
    /// - Returns: Its value, or `nil`.
    public func value(of option: String) -> String? {
        var found: String?
        var index = 0
        while index < kept.count {
            if kept[index] == option, index + 1 < kept.count {
                found = kept[index + 1]
                index += 2
                continue
            }
            if kept[index].hasPrefix(option + "=") {
                found = String(kept[index].dropFirst(option.count + 1))
            }
            index += 1
        }
        return found
    }

    /// The argv that resumes `conversation` with these options.
    ///
    /// - Parameters:
    ///   - launcher: The stable launcher (`claude`, `~/.local/bin/claude`), never a
    ///     `versions/<x>` path: after an update that would bring the old binary back.
    ///   - conversation: The proven conversation id.
    /// - Returns: `[launcher, "--resume", conversation] + kept`.
    public func resumeArgv(launcher: String, conversation: String) -> [String] {
        [launcher, "--resume", conversation] + kept
    }

    /// The launcher to reopen a Claude with, from what its process was started as.
    ///
    /// A bare name (`claude`) is resolved again by the shell, which is what picks up an update.
    /// A path inside Claude's own `versions/` folder is the **old** binary of a process started
    /// before the update, so it becomes `claude`. Any other path is kept as it was.
    ///
    /// - Parameters:
    ///   - argv0: The process's `argv[0]`.
    ///   - executable: The process's resolved executable path.
    /// - Returns: What to type as the first word of the resume command.
    public static func stableLauncher(argv0: String, executable: String?) -> String {
        if argv0.contains("/claude/versions/") || (executable ?? "").contains("/claude/versions/") {
            return argv0.contains("/") || argv0.isEmpty ? "claude" : argv0
        }
        if !argv0.isEmpty { return argv0 }
        return executable ?? "claude"
    }
}
