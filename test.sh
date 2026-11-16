#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
TEST_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ven-obs-tests.XXXXXX")"
trap 'rm -rf "$TEST_BUILD_DIR"' EXIT

printf '%s\n' 'Run backend tests'
python3 -m unittest discover -s tests -v

printf '%s\n' 'Run Swift scene automation tests'
xcrun --sdk macosx swiftc -parse-as-library \
  app/Sources/SceneAutomation.swift \
  app/Sources/AppConfig.swift \
  app/Tests/SceneAutomationTests.swift \
  -o "$TEST_BUILD_DIR/scene-automation-tests"
"$TEST_BUILD_DIR/scene-automation-tests"

printf '%s\n' 'Run config migration tests'
xcrun --sdk macosx swiftc -parse-as-library \
  app/Sources/SceneAutomation.swift \
  app/Sources/AppConfig.swift \
  app/Tests/AppConfigMigrationTests.swift \
  -o "$TEST_BUILD_DIR/app-config-migration-tests"
"$TEST_BUILD_DIR/app-config-migration-tests"

printf '%s\n' 'Run Keychain storage tests'
xcrun --sdk macosx swiftc -parse-as-library \
  -framework Security \
  app/Sources/KeychainStore.swift \
  app/Tests/KeychainStoreTests.swift \
  -o "$TEST_BUILD_DIR/keychain-store-tests"
"$TEST_BUILD_DIR/keychain-store-tests"

printf '%s\n' 'Run OBS protocol tests'
xcrun --sdk macosx swiftc -parse-as-library \
  -framework CryptoKit \
  app/Sources/OBSProtocol.swift \
  app/Tests/OBSProtocolTests.swift \
  -o "$TEST_BUILD_DIR/obs-protocol-tests"
"$TEST_BUILD_DIR/obs-protocol-tests"

printf '%s\n' 'Run OBS connection state tests'
xcrun --sdk macosx swiftc -parse-as-library \
  -framework CryptoKit \
  app/Sources/SceneAutomation.swift \
  app/Sources/OBSProtocol.swift \
  app/Sources/OBSConnectionState.swift \
  app/Tests/OBSConnectionStateTests.swift \
  -o "$TEST_BUILD_DIR/obs-connection-state-tests"
"$TEST_BUILD_DIR/obs-connection-state-tests"

printf '%s\n' 'Run OBS websocket routing tests'
xcrun --sdk macosx swiftc -parse-as-library \
  -framework CryptoKit \
  app/Sources/SceneAutomation.swift \
  app/Sources/OBSProtocol.swift \
  app/Sources/OBSConnectionState.swift \
  app/Sources/OBSWebSocketClient.swift \
  app/Tests/OBSWebSocketClientTests.swift \
  -o "$TEST_BUILD_DIR/obs-websocket-client-tests"
"$TEST_BUILD_DIR/obs-websocket-client-tests"

printf '%s\n' 'Run automation request ordering tests'
xcrun --sdk macosx swiftc -parse-as-library \
  app/Sources/SceneAutomation.swift \
  app/Sources/OBSProtocol.swift app/Sources/OBSConnectionState.swift -framework CryptoKit \
  app/Sources/AutomationRequestSequence.swift \
  app/Tests/AutomationRequestSequenceTests.swift \
  -o "$TEST_BUILD_DIR/automation-request-sequence-tests"
"$TEST_BUILD_DIR/automation-request-sequence-tests"

printf '%s\n' 'Run settings form tests'
xcrun --sdk macosx swiftc -parse-as-library \
  app/Sources/SceneAutomation.swift \
  app/Sources/AppConfig.swift \
  app/Sources/SettingsDraft.swift \
  app/Tests/SettingsDraftTests.swift \
  -o "$TEST_BUILD_DIR/settings-draft-tests"
"$TEST_BUILD_DIR/settings-draft-tests"

printf '%s\n' 'Run service restart policy tests'
xcrun --sdk macosx swiftc \
  app/Sources/ServiceRestartPolicy.swift \
  app/Tests/ServiceRestartPolicyTests.swift \
  -o "$TEST_BUILD_DIR/service-restart-policy-tests"
"$TEST_BUILD_DIR/service-restart-policy-tests"

printf '%s\n' 'Run service restart lifecycle test'
xcrun --sdk macosx swiftc -parse-as-library \
  app/Sources/ServiceController.swift \
  app/Sources/StaleHelperCleanup.swift \
  app/Sources/ServiceRestartPolicy.swift \
  app/Tests/ServiceControllerTests.swift \
  -o "$TEST_BUILD_DIR/service-controller-tests"
python3 - "$TEST_BUILD_DIR/service-controller-tests" <<'PYTEST'
import subprocess
import sys
subprocess.run([sys.argv[1]], check=True, timeout=120)
PYTEST

printf '%s\n' 'Run stale helper cleanup tests'
xcrun --sdk macosx swiftc \
  app/Sources/StaleHelperCleanup.swift \
  app/Tests/StaleHelperCleanupTests.swift \
  -o "$TEST_BUILD_DIR/stale-helper-cleanup-tests"
"$TEST_BUILD_DIR/stale-helper-cleanup-tests"

printf '%s\n' 'Run status presentation tests'
xcrun --sdk macosx swiftc -parse-as-library \
  app/Sources/StatusPresentation.swift \
  app/Tests/StatusPresentationTests.swift \
  -o "$TEST_BUILD_DIR/status-presentation-tests"
"$TEST_BUILD_DIR/status-presentation-tests"

printf '%s\n' 'Run MPS state and selection tests'
xcrun --sdk macosx swiftc -parse-as-library \
  app/Sources/MPSState.swift \
  app/Tests/MPSStateTests.swift \
  -o "$TEST_BUILD_DIR/mps-state-tests"
"$TEST_BUILD_DIR/mps-state-tests"

printf '%s\n' 'Run media heartbeat and reconnect regressions'
xcrun --sdk macosx swiftc -parse-as-library \
  app/Sources/MPSState.swift app/Sources/MediaBridgeController.swift \
  app/Tests/MediaBridgeControllerTests.swift -o "$TEST_BUILD_DIR/media-bridge-controller-tests"
"$TEST_BUILD_DIR/media-bridge-controller-tests"

printf '%s\n' 'Verify settings visibility and capture previews'
xcrun --sdk macosx swiftc -parse-as-library -framework AppKit \
  app/Sources/SceneAutomation.swift app/Sources/AppConfig.swift \
  app/Sources/SettingsDraft.swift app/Sources/SettingsWindowController.swift \
  app/Tests/SettingsWindowLayoutTests.swift -o "$TEST_BUILD_DIR/settings-layout-tests"
"$TEST_BUILD_DIR/settings-layout-tests"
