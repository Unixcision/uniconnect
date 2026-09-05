#!/bin/bash
set -euo pipefail

repo_path="$(cd "$(dirname "$0")/../.." && pwd)"
harness_path="$(mktemp -d "${TMPDIR:-/tmp}/uniconnect-mobile-behavior.XXXXXXXX")"
mkdir -p "$harness_path/Sources/cmux" "$harness_path/Tests/UniConnectMobileBehaviorTests"
cp "$repo_path/scripts/ci/uniconnect-mobile-harness/Package.swift" "$harness_path/Package.swift"

# Copy complete production files, never reimplement behavior in a test shim.
for filename in \
    Sources/TerminalStartupShellQuoting.swift \
    Sources/UniConnect/UniConnectLocalTmuxBinding.swift \
    Sources/UniConnect/UniConnectLocalTmuxLaunchPlan.swift \
    Sources/UniConnect/UniConnectLocalTmuxInspecting.swift \
    Sources/UniConnect/UniConnectLocalTmuxService.swift \
    Sources/UniConnect/UniConnectMobileApprovedPeer.swift \
    Sources/UniConnect/UniConnectMobilePendingPeer.swift \
    Sources/UniConnect/UniConnectMobileAccessRepository.swift \
    Sources/UniConnect/UniConnectMobileAccessFileRepository.swift \
    Sources/UniConnect/UniConnectMobileAccessModel.swift \
    Sources/UniConnect/UniConnectMobileRequestAuthorizer.swift \
    Sources/UniConnect/UniConnectMobilePeerEndpoint.swift \
    Sources/Mobile/MobileHostOutboundQueue.swift \
    Sources/Mobile/MobileHostRPC.swift
do
    cp "$repo_path/$filename" "$harness_path/Sources/cmux/"
done
for filename in UniConnectLocalTmuxTests.swift UniConnectLocalTmuxIntegrationTests.swift UniConnectMobileAccessTests.swift MobileHostOutboundQueueTests.swift; do
    cp "$repo_path/cmuxTests/$filename" "$harness_path/Tests/UniConnectMobileBehaviorTests/"
done
printf '%s\n' "$harness_path"
