import CMUXAgentLaunch
import Foundation
import Testing

@Suite("HermesAgentHookConfig")
struct HermesAgentHookConfigTests {
    @Test("Installs hooks into empty config")
    func installsHooksIntoEmptyConfig() {
        let events = [
            HermesAgentHookConfig.Event(name: "on_session_start", command: "sh -c 'cmux hooks hermes-agent session-start'"),
            HermesAgentHookConfig.Event(name: "pre_tool_call", command: "sh -c 'cmux hooks feed --source hermes-agent --event pre_tool_call'", timeout: 120),
        ]

        let installed = HermesAgentHookConfig.installing(events: events, in: "")

        #expect(installed.contains("# uniconnect hooks hermes-agent begin\nhooks:\n  on_session_start:"))
        #expect(installed.contains("    - command: \"sh -c 'cmux hooks hermes-agent session-start'\""))
        #expect(installed.contains("      timeout: 120"))
        #expect(HermesAgentHookConfig.uninstalling(from: installed) == "")
    }

    @Test("Coalesces multiple cmux hooks for the same missing Hermes event")
    func coalescesMultipleHooksForSameMissingEvent() {
        let events = [
            HermesAgentHookConfig.Event(name: "pre_approval_request", command: "sh -c 'cmux hooks hermes-agent notification'"),
            HermesAgentHookConfig.Event(name: "pre_approval_request", command: "sh -c 'cmux hooks feed --source hermes-agent --event pre_approval_request'", timeout: 120),
            HermesAgentHookConfig.Event(name: "post_llm_call", command: "sh -c 'cmux hooks hermes-agent agent-response'"),
        ]

        let installed = HermesAgentHookConfig.installing(events: events, in: "")

        #expect(installed.components(separatedBy: "\n  pre_approval_request:").count == 2)
        #expect(
            installed.contains("""
              pre_approval_request:
                - command: "sh -c 'cmux hooks hermes-agent notification'"
                  timeout: 5
                - command: "sh -c 'cmux hooks feed --source hermes-agent --event pre_approval_request'"
                  timeout: 120
            """)
        )
        #expect(installed.contains("  post_llm_call:"))
        #expect(HermesAgentHookConfig.uninstalling(from: installed) == "")
    }

    @Test("Coalesces multiple cmux hooks for the same existing Hermes event")
    func coalescesMultipleHooksForSameExistingEvent() {
        let existing = """
        hooks:
          pre_approval_request:
            - command: "echo user"
              timeout: 10

        """
        let events = [
            HermesAgentHookConfig.Event(name: "pre_approval_request", command: "sh -c 'cmux hooks hermes-agent notification'"),
            HermesAgentHookConfig.Event(name: "pre_approval_request", command: "sh -c 'cmux hooks feed --source hermes-agent --event pre_approval_request'", timeout: 120),
        ]

        let installed = HermesAgentHookConfig.installing(events: events, in: existing)

        #expect(installed.components(separatedBy: "\n  pre_approval_request:").count == 2)
        #expect(
            installed.contains("""
              pre_approval_request:
                # uniconnect hooks hermes-agent begin
                - command: "sh -c 'cmux hooks hermes-agent notification'"
                  timeout: 5
                - command: "sh -c 'cmux hooks feed --source hermes-agent --event pre_approval_request'"
                  timeout: 120
                # uniconnect hooks hermes-agent end
                - command: "echo user"
                  timeout: 10
            """)
        )
        #expect(HermesAgentHookConfig.uninstalling(from: installed) == existing)
    }

    @Test("Preserves existing hook events without duplicating keys")
    func preservesExistingHookEventsWithoutDuplicatingKeys() {
        let existing = """
        model: anthropic/claude-sonnet-4.6
        hooks:
          pre_tool_call:
            - command: "echo user"
              timeout: 10
          post_llm_call:
            - command: "echo done"

        """
        let events = [
            HermesAgentHookConfig.Event(name: "pre_tool_call", command: "sh -c 'cmux hooks feed --source hermes-agent --event pre_tool_call'", timeout: 120),
            HermesAgentHookConfig.Event(name: "on_session_end", command: "sh -c 'cmux hooks hermes-agent stop'"),
        ]

        let installed = HermesAgentHookConfig.installing(events: events, in: existing)

        #expect(installed.components(separatedBy: "\n  pre_tool_call:").count == 2)
        #expect(installed.contains("  pre_tool_call:\n    # uniconnect hooks hermes-agent begin\n    - command: \"sh -c 'cmux hooks feed --source hermes-agent --event pre_tool_call'\""))
        #expect(installed.contains("    - command: \"echo user\""))
        #expect(installed.contains("  on_session_end:"))
        #expect(HermesAgentHookConfig.uninstalling(from: installed) == existing)
    }

    @Test("Installs into multiple existing hook events without shifting later indexes")
    func installsIntoMultipleExistingEventsWithoutShiftingLaterIndexes() {
        let existing = """
        hooks:
          pre_tool_call:
            - command: "echo pre"
          post_tool_call:
            - command: "echo post"

        """
        let events = [
            HermesAgentHookConfig.Event(name: "pre_tool_call", command: "sh -c 'cmux hooks feed --source hermes-agent --event pre_tool_call'"),
            HermesAgentHookConfig.Event(name: "post_tool_call", command: "sh -c 'cmux hooks feed --source hermes-agent --event post_tool_call'"),
        ]

        let installed = HermesAgentHookConfig.installing(events: events, in: existing)

        #expect(installed.contains("  pre_tool_call:\n    # uniconnect hooks hermes-agent begin"))
        #expect(installed.contains("  post_tool_call:\n    # uniconnect hooks hermes-agent begin"))
        #expect(installed.contains("    - command: \"echo pre\""))
        #expect(installed.contains("    - command: \"echo post\""))
        #expect(HermesAgentHookConfig.uninstalling(from: installed) == existing)
    }

    @Test("Installs into inline-empty hook events")
    func installsIntoInlineEmptyHookEvents() {
        let existing = """
        hooks:
          pre_tool_call: []
          post_tool_call: {} # intentionally empty

        """
        let events = [
            HermesAgentHookConfig.Event(name: "pre_tool_call", command: "sh -c 'cmux hooks feed --source hermes-agent --event pre_tool_call'"),
            HermesAgentHookConfig.Event(name: "post_tool_call", command: "sh -c 'cmux hooks feed --source hermes-agent --event post_tool_call'"),
        ]

        let installed = HermesAgentHookConfig.installing(events: events, in: existing)

        #expect(installed.contains("  pre_tool_call:\n    # uniconnect hooks hermes-agent begin"))
        #expect(installed.contains("  post_tool_call:\n    # uniconnect hooks hermes-agent begin"))
        #expect(!installed.contains("pre_tool_call: []\n    # uniconnect hooks hermes-agent begin"))
        #expect(!installed.contains("post_tool_call: {} # intentionally empty\n    # uniconnect hooks hermes-agent begin"))
        #expect(HermesAgentHookConfig.uninstalling(from: installed) == existing)
    }

    @Test("Uninstalls inline-empty hooks root")
    func uninstallsInlineEmptyHooksRoot() {
        let existing = """
        model: anthropic/claude-sonnet-4.6
        hooks: [] # intentionally empty

        """
        let events = [
            HermesAgentHookConfig.Event(name: "pre_tool_call", command: "sh -c 'cmux hooks feed --source hermes-agent --event pre_tool_call'"),
            HermesAgentHookConfig.Event(name: "post_tool_call", command: "sh -c 'cmux hooks feed --source hermes-agent --event post_tool_call'"),
        ]

        let installed = HermesAgentHookConfig.installing(events: events, in: existing)

        #expect(installed.contains("hooks:\n  # uniconnect hooks hermes-agent begin restore-line-base64:"))
        #expect(installed.contains("  pre_tool_call:"))
        #expect(HermesAgentHookConfig.uninstalling(from: installed) == existing)
    }

    @Test("Install and uninstall preserve upstream cmux hook blocks")
    func preservesUpstreamCmuxHookBlocks() {
        let existing = """
        hooks:
          pre_tool_call:
            # cmux hooks hermes-agent begin
            - command: "sh -c 'cmux hooks feed --source hermes-agent --event pre_tool_call'"
              timeout: 120
            # cmux hooks hermes-agent end

        """
        let events = [
            HermesAgentHookConfig.Event(
                name: "pre_tool_call",
                command: "sh -c ': uniconnect-agent-hook-v1:hermes-agent; cmux hooks feed --source hermes-agent --event pre_tool_call'",
                timeout: 120
            ),
        ]

        let installed = HermesAgentHookConfig.installing(events: events, in: existing)
        let reinstalled = HermesAgentHookConfig.installing(events: events, in: installed)

        #expect(installed.contains("# cmux hooks hermes-agent begin"))
        #expect(installed.contains("# uniconnect hooks hermes-agent begin"))
        #expect(reinstalled == installed)
        #expect(HermesAgentHookConfig.uninstalling(from: installed) == existing)
    }

    @Test("Allowlist install and uninstall only touches UniConnect commands")
    func allowlistInstallAndUninstallOnlyTouchesUniConnectCommands() throws {
        let existing = """
        {
          "approvals": [
            {
              "command": "echo user",
              "event": "pre_tool_call"
            },
            {
              "command": "sh -c 'cmux hooks feed --source hermes-agent --event pre_tool_call'",
              "event": "pre_tool_call",
              "scope": "upstream-cmux"
            },
            {
              "command": "sh -c ': uniconnect-agent-hook-v1:hermes-agent; cmux hooks feed --source hermes-agent --event stale'",
              "event": "pre_tool_call",
              "scope": "stale-uniconnect"
            }
          ]
        }
        """.data(using: .utf8)
        let events = [
            HermesAgentHookConfig.Event(
                name: "pre_tool_call",
                command: "sh -c ': uniconnect-agent-hook-v1:hermes-agent; cmux hooks feed --source hermes-agent --event pre_tool_call'",
                timeout: 120
            ),
        ]

        let installed = try HermesAgentHookAllowlist.installing(
            events: events,
            in: existing,
            approvedAt: Date(timeIntervalSince1970: 0)
        )
        let installedObject = try #require(JSONSerialization.jsonObject(with: installed) as? [String: Any])
        let approvals = try #require(installedObject["approvals"] as? [[String: Any]])
        #expect(approvals.count == 3)
        #expect(!approvals.contains { $0["scope"] as? String == "stale-uniconnect" })

        let uninstalled = try HermesAgentHookAllowlist.uninstalling(events: events, from: installed)
        let uninstalledObject = try #require(JSONSerialization.jsonObject(with: uninstalled) as? [String: Any])
        let remaining = try #require(uninstalledObject["approvals"] as? [[String: Any]])
        #expect(remaining.count == 2)
        #expect(remaining.contains { $0["command"] as? String == "echo user" })
        #expect(remaining.contains { $0["scope"] as? String == "upstream-cmux" })
    }

    @Test("Allowlist install preserves non-conforming approvals")
    func allowlistInstallPreservesNonConformingApprovals() throws {
        let existing = """
        {
          "approvals": [
            {
              "event": "pre_tool_call",
              "command": 12,
              "scope": "third-party"
            }
          ]
        }
        """.data(using: .utf8)
        let events = [
            HermesAgentHookConfig.Event(name: "pre_tool_call", command: "sh -c 'cmux hooks feed --source hermes-agent --event pre_tool_call'"),
        ]

        let installed = try HermesAgentHookAllowlist.installing(events: events, in: existing)
        let installedObject = try #require(JSONSerialization.jsonObject(with: installed) as? [String: Any])
        let approvals = try #require(installedObject["approvals"] as? [[String: Any]])

        #expect(approvals.count == 2)
        #expect(approvals.contains { $0["scope"] as? String == "third-party" })
        #expect(approvals.contains { $0["command"] as? String == events[0].command })
    }

    @Test("Allowlist install rejects non-object JSON roots")
    func allowlistInstallRejectsNonObjectJSONRoots() throws {
        let existing = #"[]"#.data(using: .utf8)
        let events = [
            HermesAgentHookConfig.Event(name: "pre_tool_call", command: "sh -c 'cmux hooks feed --source hermes-agent --event pre_tool_call'"),
        ]

        do {
            _ = try HermesAgentHookAllowlist.installing(events: events, in: existing)
            Issue.record("expected non-object allowlist JSON to throw")
        } catch {}
    }
}
