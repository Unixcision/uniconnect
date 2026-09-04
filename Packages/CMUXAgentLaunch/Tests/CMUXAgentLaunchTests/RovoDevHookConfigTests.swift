import CMUXAgentLaunch
import Testing

@Suite("RovoDevHookConfig")
struct RovoDevHookConfigTests {
    @Test("Installs into direct eventHooks events child only")
    func installsIntoDirectEventHooksEventsChildOnly() {
        let existing = """
        eventHooks:
          nested:
            events:
              - name: user_hook
                commands:
                  - command: "echo user"

        """

        let events = [
            RovoDevHookConfig.Event(
                name: "on_complete",
                command: "cmux hooks rovodev stop"
            ),
        ]
        let installed = RovoDevHookConfig.installing(events: events, in: existing)

        #expect(installed.contains("eventHooks:\n  # uniconnect hooks rovodev begin\n  events:"))
        #expect(installed.contains("    events:\n      - name: user_hook"))
        #expect(RovoDevHookConfig.uninstalling(from: installed) == existing)
    }

    @Test("Dangling upstream cmux marker does not drop following YAML")
    func danglingMarkerDoesNotDropFollowingYAML() {
        let existing = """
        eventHooks:
          events:
            # cmux hooks rovodev begin
        sessions:
          persistenceDir: /tmp/rovo

        """

        let events = [
            RovoDevHookConfig.Event(
                name: "on_complete",
                command: "cmux hooks rovodev stop"
            ),
        ]
        let installed = RovoDevHookConfig.installing(events: events, in: existing)
        let uninstalled = RovoDevHookConfig.uninstalling(from: existing)

        #expect(installed.contains("sessions:\n  persistenceDir: /tmp/rovo"))
        #expect(uninstalled.contains("sessions:\n  persistenceDir: /tmp/rovo"))
    }

    @Test("Install and uninstall preserve an upstream cmux hook block")
    func preservesUpstreamCmuxHookBlock() {
        let existing = """
        eventHooks:
          events:
            # cmux hooks rovodev begin
            - name: on_complete
              commands:
                - command: "cmux hooks rovodev stop"
            # cmux hooks rovodev end

        """
        let events = [
            RovoDevHookConfig.Event(
                name: "on_complete",
                command: ": 'uniconnect-agent-hook-v1:rovodev'; cmux hooks rovodev stop"
            ),
        ]

        let installed = RovoDevHookConfig.installing(events: events, in: existing)
        let reinstalled = RovoDevHookConfig.installing(events: events, in: installed)

        #expect(installed.contains("# cmux hooks rovodev begin"))
        #expect(installed.contains("# uniconnect hooks rovodev begin"))
        #expect(reinstalled == installed)
        #expect(RovoDevHookConfig.uninstalling(from: installed) == existing)
    }
}
