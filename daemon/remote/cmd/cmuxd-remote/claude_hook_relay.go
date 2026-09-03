package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"os"
	"strings"
	"time"
)

const maximumClaudeHookPayloadBytes = 1024 * 1024

type claudeHookRelayInput struct {
	SessionID        string `json:"session_id"`
	Cwd              string `json:"cwd"`
	NotificationType string `json:"notification_type"`
}

// runHooksRelay keeps remote Claude hooks best-effort: an unavailable Mac never blocks Claude.
func runHooksRelay(socketPath string, args []string, refreshAddr func() string) int {
	payload, err := io.ReadAll(io.LimitReader(os.Stdin, maximumClaudeHookPayloadBytes+1))
	if err != nil || len(payload) == 0 || len(payload) > maximumClaudeHookPayloadBytes {
		writeEmptyHookResponse()
		return 0
	}

	if len(args) < 2 || args[0] != "claude" {
		writeEmptyHookResponse()
		return 0
	}

	params, ok := claudeBridgeParams(args[1], payload, processEnvironment(), time.Now())
	if !ok {
		writeEmptyHookResponse()
		return 0
	}

	_, _ = socketRoundTripV2(
		socketPath,
		"notification.create_from_claude_bridge",
		params,
		refreshAddr,
	)
	writeEmptyHookResponse()
	return 0
}

func claudeBridgeParams(
	subcommand string,
	payload []byte,
	environment map[string]string,
	now time.Time,
) (map[string]any, bool) {
	var input claudeHookRelayInput
	if err := json.Unmarshal(payload, &input); err != nil {
		return nil, false
	}

	eventType := ""
	switch subcommand {
	case "stop":
		eventType = "stop"
	case "notification":
		if strings.TrimSpace(input.NotificationType) != "idle_prompt" {
			return nil, false
		}
		eventType = "idle_prompt"
	default:
		return nil, false
	}

	workspaceID := strings.TrimSpace(environment["CMUX_WORKSPACE_ID"])
	surfaceID := strings.TrimSpace(environment["CMUX_SURFACE_ID"])
	sessionID := strings.TrimSpace(input.SessionID)
	cwd := strings.TrimSpace(input.Cwd)
	if !isCanonicalUUID(workspaceID) || !isCanonicalUUID(surfaceID) || !isCanonicalUUID(sessionID) {
		return nil, false
	}
	if len(cwd) == 0 || len(cwd) > 4096 || !strings.HasPrefix(cwd, "/") || strings.ContainsRune(cwd, '\x00') {
		return nil, false
	}

	fingerprintInput := make([]byte, 0, len(payload)+len(subcommand)+len(workspaceID)+len(surfaceID)+8)
	fingerprintInput = append(fingerprintInput, "uniconnect-claude-bridge-v1\x00"...)
	fingerprintInput = append(fingerprintInput, subcommand...)
	fingerprintInput = append(fingerprintInput, 0)
	fingerprintInput = append(fingerprintInput, workspaceID...)
	fingerprintInput = append(fingerprintInput, 0)
	fingerprintInput = append(fingerprintInput, surfaceID...)
	fingerprintInput = append(fingerprintInput, 0)
	fingerprintInput = append(fingerprintInput, payload...)
	fingerprint := sha256.Sum256(fingerprintInput)

	params := map[string]any{
		"event_id":           hex.EncodeToString(fingerprint[:]),
		"event_timestamp_ms": now.UnixMilli(),
		"event_type":         eventType,
		"workspace_id":       workspaceID,
		"surface_id":         surfaceID,
		"session_id":         sessionID,
		"cwd":                cwd,
	}
	if hostID := normalizedBridgeIdentifier(environment["UNICONNECT_BRIDGE_HOST_ID"], 160); hostID != "" {
		params["host_id"] = hostID
	}
	if tmuxPane := normalizedTmuxPane(environment["TMUX_PANE"]); tmuxPane != "" {
		params["tmux_pane"] = tmuxPane
	}
	return params, true
}

func processEnvironment() map[string]string {
	result := make(map[string]string)
	for _, entry := range os.Environ() {
		key, value, found := strings.Cut(entry, "=")
		if found {
			result[key] = value
		}
	}
	return result
}

func isCanonicalUUID(value string) bool {
	if len(value) != 36 {
		return false
	}
	for index, character := range value {
		switch index {
		case 8, 13, 18, 23:
			if character != '-' {
				return false
			}
		default:
			if !((character >= '0' && character <= '9') || (character >= 'a' && character <= 'f') || (character >= 'A' && character <= 'F')) {
				return false
			}
		}
	}
	return true
}

func normalizedBridgeIdentifier(value string, maximumLength int) string {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" || len(trimmed) > maximumLength {
		return ""
	}
	for _, character := range trimmed {
		if (character >= 'a' && character <= 'z') ||
			(character >= 'A' && character <= 'Z') ||
			(character >= '0' && character <= '9') ||
			strings.ContainsRune("._:@-", character) {
			continue
		}
		return ""
	}
	return trimmed
}

func normalizedTmuxPane(value string) string {
	trimmed := strings.TrimSpace(value)
	if len(trimmed) < 2 || len(trimmed) > 13 || trimmed[0] != '%' {
		return ""
	}
	for _, character := range trimmed[1:] {
		if character < '0' || character > '9' {
			return ""
		}
	}
	return trimmed
}

func writeEmptyHookResponse() {
	_, _ = os.Stdout.WriteString("{}\n")
}
