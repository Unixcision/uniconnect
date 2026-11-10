import Foundation

/// `mobile.accounts.list`: the snapshot in the exact shape of `contracts/accounts-v1/accounts-response.json`.
extension UniConnectAccountsSnapshot {
    /// Every key always present; `NSNull` where it does not apply; dates in ISO 8601 UTC.
    var mobilePayload: [String: Any] {
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime]
        dates.timeZone = TimeZone(identifier: "UTC")
        func value(_ optional: Any?) -> Any { optional ?? NSNull() }
        func date(_ optional: Date?) -> Any { optional.map { dates.string(from: $0) } ?? NSNull() }
        func limits(_ limits: [Limit]) -> [[String: Any]] {
            limits.map {
                ["id": $0.id, "used_percent": $0.usedPercent, "resets_at": date($0.resetsAt),
                 "window_minutes": value($0.windowMinutes)]
            }
        }
        func usage(_ usage: Usage?, withHost: Bool) -> Any {
            guard let usage else { return NSNull() }
            var result: [String: Any] = [
                "source": usage.source, "observed_at": dates.string(from: usage.observedAt),
                "limits": limits(usage.limits),
            ]
            if withHost { result["host_key"] = value(usage.hostKey) }
            if let credits = usage.resetCredits {
                result["reset_credits"] = ["available": credits.available, "next_expires_at": date(credits.nextExpiresAt)]
            }
            return result
        }
        return [
            "version": 1,
            "checked_at": dates.string(from: checkedAt),
            "hosts": hosts.map {
                ["host_key": $0.key, "label": $0.label, "kind": $0.kind, "state": $0.state.rawValue,
                 "checked_at": dates.string(from: $0.checkedAt), "error": value($0.error)] as [String: Any]
            },
            "windows": windows.map { window -> [String: Any] in
                let agent: Any = window.agent.map {
                    ["provider": $0.provider, "display_name": $0.displayName, "as_root": $0.asRoot] as [String: Any]
                } ?? NSNull()
                let account: Any = window.account.map {
                    ["email": value($0.email), "method": value($0.method), "plan": value($0.plan),
                     "organization": value($0.organization), "os_user": value($0.osUser), "config": value($0.config),
                     "read_at": date($0.readAt), "usage": usage($0.usage, withHost: false)] as [String: Any]
                } ?? NSNull()
                return [
                    "workspace_id": window.workspaceID.uuidString.lowercased(),
                    "workspace": window.workspace,
                    "terminal_id": window.terminalID.uuidString.lowercased(),
                    "window": window.window,
                    "host_key": window.hostKey,
                    "tmux_session": value(window.tmuxSession),
                    "state": window.state.rawValue,
                    "agent": agent,
                    "account": account,
                ]
            },
            "accounts": accounts.map { account -> [String: Any] in
                [
                    "key": account.key, "provider": account.provider, "display_name": account.displayName,
                    "email": account.email, "plan": value(account.plan), "organization": value(account.organization),
                    "windows": account.windows, "host_keys": account.hostKeys,
                    "usage": usage(account.usage, withHost: true),
                    "history": account.history.map {
                        ["at": dates.string(from: $0.at), "limits": $0.limits] as [String: Any]
                    },
                ]
            },
        ]
    }
}
