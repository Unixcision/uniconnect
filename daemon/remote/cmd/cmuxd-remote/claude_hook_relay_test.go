package main

import (
	"encoding/json"
	"reflect"
	"testing"
	"time"
)

func TestClaudeBridgeParamsStopMinimizesPayload(t *testing.T) {
	environment := map[string]string{
		"CMUX_WORKSPACE_ID":          "11111111-1111-4111-8111-111111111111",
		"CMUX_SURFACE_ID":            "22222222-2222-4222-8222-222222222222",
		"UNICONNECT_BRIDGE_HOST_ID": "credential-7@example.test:22",
		"TMUX_PANE":                  "%12",
	}
	payload := []byte(`{
		"session_id":"33333333-3333-4333-8333-333333333333",
		"cwd":"/srv/example project",
		"last_assistant_message":"private response that must never cross the bridge",
		"transcript_path":"/private/transcript.jsonl"
	}`)
	now := time.Unix(1_800_000_000, 250_000_000)

	params, ok := claudeBridgeParams("stop", payload, environment, now)
	if !ok {
		t.Fatal("expected a valid Stop event")
	}
	if params["event_type"] != "stop" {
		t.Fatalf("unexpected event type: %v", params["event_type"])
	}
	if params["event_timestamp_ms"] != now.UnixMilli() {
		t.Fatalf("unexpected timestamp: %v", params["event_timestamp_ms"])
	}
	if params["tmux_pane"] != "%12" {
		t.Fatalf("unexpected tmux pane: %v", params["tmux_pane"])
	}
	encoded, err := json.Marshal(params)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"last_assistant_message", "private response", "transcript_path", "transcript.jsonl"} {
		if containsString(string(encoded), forbidden) {
			t.Fatalf("privacy-sensitive field crossed bridge: %q", forbidden)
		}
	}
}

func TestClaudeBridgeParamsAcceptsOnlyIdlePromptNotification(t *testing.T) {
	environment := validClaudeBridgeEnvironment()
	now := time.Unix(1_800_000_000, 0)
	idlePayload := []byte(`{"session_id":"33333333-3333-4333-8333-333333333333","cwd":"/srv/app","notification_type":"idle_prompt"}`)
	params, ok := claudeBridgeParams("notification", idlePayload, environment, now)
	if !ok || params["event_type"] != "idle_prompt" {
		t.Fatalf("expected idle_prompt event, got %#v", params)
	}

	nonIdlePayload := []byte(`{"session_id":"33333333-3333-4333-8333-333333333333","cwd":"/srv/app","notification_type":"permission_prompt"}`)
	if _, ok := claudeBridgeParams("notification", nonIdlePayload, environment, now); ok {
		t.Fatal("permission notifications must not be presented as completion events")
	}
}

func TestClaudeBridgeParamsRejectsUnsafeIdentityAndPath(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	validPayload := []byte(`{"session_id":"33333333-3333-4333-8333-333333333333","cwd":"/srv/app"}`)

	missingSurface := validClaudeBridgeEnvironment()
	delete(missingSurface, "CMUX_SURFACE_ID")
	if _, ok := claudeBridgeParams("stop", validPayload, missingSurface, now); ok {
		t.Fatal("missing surface identity must fail closed")
	}

	relativePath := []byte(`{"session_id":"33333333-3333-4333-8333-333333333333","cwd":"relative/path"}`)
	if _, ok := claudeBridgeParams("stop", relativePath, validClaudeBridgeEnvironment(), now); ok {
		t.Fatal("relative cwd must fail closed")
	}
}

func TestClaudeBridgeParamsProducesStableEventIDForDuplicateInput(t *testing.T) {
	payload := []byte(`{"session_id":"33333333-3333-4333-8333-333333333333","cwd":"/srv/app"}`)
	environment := validClaudeBridgeEnvironment()
	first, firstOK := claudeBridgeParams("stop", payload, environment, time.Unix(1_800_000_000, 0))
	second, secondOK := claudeBridgeParams("stop", payload, environment, time.Unix(1_800_000_010, 0))
	if !firstOK || !secondOK {
		t.Fatal("expected valid duplicate events")
	}
	if !reflect.DeepEqual(first["event_id"], second["event_id"]) {
		t.Fatalf("duplicate event IDs differ: %v != %v", first["event_id"], second["event_id"])
	}
}

func validClaudeBridgeEnvironment() map[string]string {
	return map[string]string{
		"CMUX_WORKSPACE_ID": "11111111-1111-4111-8111-111111111111",
		"CMUX_SURFACE_ID":   "22222222-2222-4222-8222-222222222222",
	}
}

func containsString(value string, fragment string) bool {
	for index := 0; index+len(fragment) <= len(value); index++ {
		if value[index:index+len(fragment)] == fragment {
			return true
		}
	}
	return false
}
