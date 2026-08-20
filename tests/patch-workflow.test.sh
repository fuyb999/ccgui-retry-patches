#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="$ROOT_DIR/scripts/build.sh"
VERIFY_SCRIPT="$ROOT_DIR/scripts/verify.sh"
TEMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEMP_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"
}

assert_file() {
  [[ -f "$1" ]] || fail "expected file: $1"
}

run_expect_failure() {
  local expected="$1"
  shift
  local output
  local status
  set +e
  output="$($@ 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || fail "command unexpectedly succeeded: $*"
  assert_contains "$output" "$expected"
}

create_fixture() {
  FIXTURE_REPO="$TEMP_ROOT/upstream"
  FIXTURE_MANIFESTS="$TEMP_ROOT/manifests"
  FIXTURE_PATCH="$TEMP_ROOT/fixture.patch"
  FIXTURE_WORK="$TEMP_ROOT/work"
  FIXTURE_DIST="$TEMP_ROOT/dist"
  mkdir -p "$FIXTURE_REPO/ai-bridge/services/codex" "$FIXTURE_REPO/webview" "$FIXTURE_MANIFESTS"

  printf "version = '0.5'\n" > "$FIXTURE_REPO/build.gradle"
  printf '{"name":"ai-bridge","version":"1.0.0","type":"module"}\n' > "$FIXTURE_REPO/ai-bridge/package.json"
  printf '%s\n' \
    '{' \
    '  "name": "fixture-webview",' \
    '  "version": "1.0.0",' \
    '  "scripts": {' \
    '    "prebuild": "node -e \"require('\''fs'\'').appendFileSync('\''../build-gates.log'\'', '\''webview-prebuild\\n'\'')\"",' \
    '    "test": "node -e \"require('\''fs'\'').appendFileSync('\''../build-gates.log'\'', '\''webview-test\\n'\'')\""' \
    '  }' \
    '}' \
    > "$FIXTURE_REPO/webview/package.json"
  printf '%s\n' \
    '{' \
    '  "name": "fixture-webview",' \
    '  "version": "1.0.0",' \
    '  "lockfileVersion": 3,' \
    '  "requires": true,' \
    '  "packages": {' \
    '    "": { "name": "fixture-webview", "version": "1.0.0" }' \
    '  }' \
    '}' \
    > "$FIXTURE_REPO/webview/package-lock.json"
  printf "export const retryEnabled = false;\n" > "$FIXTURE_REPO/ai-bridge/services/codex/message-service.js"
  printf "export const handlerVersion = 'fixture';\n" > "$FIXTURE_REPO/ai-bridge/services/codex/codex-event-handler.js"
  printf '%s\n' \
    "import test from 'node:test';" \
    "import assert from 'node:assert/strict';" \
    "import { retryEnabled } from './message-service.js';" \
    "test('fixture patch applied', () => assert.equal(retryEnabled, true));" \
    > "$FIXTURE_REPO/ai-bridge/services/codex/fixture.test.js"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'case "${1:-}" in' \
    '  test)' \
    '    printf "gradle-test\\n" >> build-gates.log' \
    '    ;;' \
    '  buildPlugin)' \
    '    printf "build-plugin\\n" >> build-gates.log' \
    '    mkdir -p build/distributions' \
    '    package_dir="$(mktemp -d)"' \
    '    jar_dir="$(mktemp -d)"' \
    '    mkdir -p "$package_dir/ccgui/lib" "$jar_dir/META-INF" "$jar_dir/html" "$jar_dir/filler"' \
    '    printf "<idea-plugin><version>0.5-retry.1</version></idea-plugin>\\n" > "$jar_dir/META-INF/plugin.xml"' \
    '    printf "<script>window.onCodexRetryState = true;</script><div class=codex-retry-status></div>\\n" > "$jar_dir/html/claude-chat.html"' \
    '    for i in $(seq 1 5000); do : > "$jar_dir/filler/entry-$i"; done' \
    '    (cd "$jar_dir" && zip -qr "$package_dir/ccgui/lib/ccgui-0.5.jar" META-INF/plugin.xml html/claude-chat.html filler)' \
    '    (cd ai-bridge && zip -qr "$package_dir/ccgui/ai-bridge.zip" .)' \
    '    (cd "$package_dir" && zip -qr "$OLDPWD/build/distributions/ccgui-0.5.zip" ccgui)' \
    '    rm -rf "$package_dir" "$jar_dir"' \
    '    ;;' \
    '  *) exit 2 ;;' \
    'esac' \
    > "$FIXTURE_REPO/gradlew"
  chmod +x "$FIXTURE_REPO/gradlew"

  git -C "$FIXTURE_REPO" init -q
  git -C "$FIXTURE_REPO" add .
  git -C "$FIXTURE_REPO" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm fixture
  git -C "$FIXTURE_REPO" tag v0.5
  FIXTURE_COMMIT="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"
  FIXTURE_MESSAGE_HASH="$(sha256sum "$FIXTURE_REPO/ai-bridge/services/codex/message-service.js" | awk '{print $1}')"
  FIXTURE_HANDLER_HASH="$(sha256sum "$FIXTURE_REPO/ai-bridge/services/codex/codex-event-handler.js" | awk '{print $1}')"

  printf '%s\n' \
    "export const retryEnabled = true;" \
    "export const CODEX_SESSION_POLL_INTERVAL_MS = 3000;" \
    > "$FIXTURE_REPO/ai-bridge/services/codex/message-service.js"
  printf "export const retryDelayMs = 30000;\n" > "$FIXTURE_REPO/ai-bridge/services/codex/codex-retry.js"
  git -C "$FIXTURE_REPO" add -N ai-bridge/services/codex/codex-retry.js
  git -C "$FIXTURE_REPO" diff --binary > "$FIXTURE_PATCH"
  git -C "$FIXTURE_REPO" reset -q
  git -C "$FIXTURE_REPO" checkout -- ai-bridge/services/codex/message-service.js
  rm -f "$FIXTURE_REPO/ai-bridge/services/codex/codex-retry.js"

  jq -n \
    --arg repository "$FIXTURE_REPO" \
    --arg commit "$FIXTURE_COMMIT" \
    --arg messageHash "$FIXTURE_MESSAGE_HASH" \
    --arg handlerHash "$FIXTURE_HANDLER_HASH" \
    --arg patch "$FIXTURE_PATCH" \
    '{
      schemaVersion: 1,
      version: "v0.5",
      upstream: { repository: $repository, tag: "v0.5", commit: $commit },
      pluginVersion: "0.5",
      patchedPluginVersion: "0.5-retry.1",
      bridgeVersion: "1.0.0",
      sourceHashes: {
        "ai-bridge/services/codex/message-service.js": $messageHash,
        "ai-bridge/services/codex/codex-event-handler.js": $handlerHash
      },
      patches: [$patch],
      tests: ["ai-bridge/services/codex/fixture.test.js"],
      artifact: "ccgui-0.5-retry.1.zip"
    }' > "$FIXTURE_MANIFESTS/v0.5.json"
  cp "$FIXTURE_MANIFESTS/v0.5.json" "$FIXTURE_MANIFESTS/v0.5.clean.json"
}

fixture_command() {
  CCGUI_TEST_MODE=1 \
  CCGUI_MANIFEST_DIR_OVERRIDE="$FIXTURE_MANIFESTS" \
  CCGUI_UPSTREAM_REPOSITORY_OVERRIDE="$FIXTURE_REPO" \
  CCGUI_WORK_DIR_OVERRIDE="$FIXTURE_WORK" \
  CCGUI_DIST_DIR_OVERRIDE="$FIXTURE_DIST" \
  "$@"
}

test_unsupported_version_is_rejected() {
  run_expect_failure 'Unsupported CC GUI version: v9.9' "$BUILD_SCRIPT" v9.9
}

test_fixture_build_and_verify_succeed() {
  fixture_command "$BUILD_SCRIPT" v0.5
  assert_file "$FIXTURE_DIST/ccgui-0.5-retry.1.zip"
  assert_file "$FIXTURE_DIST/ccgui-0.5-retry.1.zip.sha256"
  [[ "$(<"$FIXTURE_WORK/v0.5/build-gates.log")" == $'webview-prebuild\nwebview-test\ngradle-test\nbuild-plugin' ]] || \
    fail "release build did not prepare the WebView, run tests, and package in order"
  fixture_command "$VERIFY_SCRIPT" v0.5
}

test_commit_mismatch_is_rejected() {
  jq '.upstream.commit = "0000000000000000000000000000000000000000"' \
    "$FIXTURE_MANIFESTS/v0.5.clean.json" > "$FIXTURE_MANIFESTS/v0.5.json"
  run_expect_failure 'Tag/commit mismatch' fixture_command "$BUILD_SCRIPT" v0.5 --prepare-only
}

test_source_hash_mismatch_is_rejected() {
  jq '.sourceHashes["ai-bridge/services/codex/message-service.js"] = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"' \
    "$FIXTURE_MANIFESTS/v0.5.clean.json" > "$FIXTURE_MANIFESTS/v0.5.json"
  run_expect_failure 'Source hash mismatch' fixture_command "$BUILD_SCRIPT" v0.5 --prepare-only
}

test_patch_failure_is_rejected() {
  cp "$FIXTURE_MANIFESTS/v0.5.clean.json" "$FIXTURE_MANIFESTS/v0.5.json"
  printf 'not a git patch\n' > "$FIXTURE_PATCH"
  run_expect_failure 'Patch does not apply cleanly' fixture_command "$BUILD_SCRIPT" v0.5 --prepare-only
}

test_v052_patch_contains_every_created_retry_file() {
  local patch="$ROOT_DIR/patches/v0.5.2/0001-codex-infinite-retry.patch"
  local created_paths
  local required_path
  assert_file "$patch"
  created_paths="$(git apply --summary "$patch" | sed -n 's/^[[:space:]]*create mode [0-9][0-9]* //p')"

  for required_path in \
    ai-bridge/services/codex/codex-fork.js \
    ai-bridge/services/codex/codex-fork.test.js \
    ai-bridge/services/codex/codex-retry.js \
    ai-bridge/services/codex/codex-retry.test.js \
    ai-bridge/services/codex/message-service.retry.test.js \
    ai-bridge/services/session-titles-service.test.cjs \
    src/main/java/com/github/claudecodegui/session/CanonicalSessionTitleExtractor.java \
    src/test/java/com/github/claudecodegui/session/CanonicalSessionTitleExtractorTest.java \
    webview/src/components/ChatHeader/ChatHeader.test.tsx \
    webview/src/components/RetryStatusStrip.tsx \
    webview/src/components/RetryStatusStrip.test.tsx \
    webview/src/components/WaitingIndicator.test.tsx; do
    while IFS= read -r created_path; do
      [[ "$created_path" == "$required_path" ]] && continue 2
    done <<< "$created_paths"
    fail "v0.5.2 create-mode file missing from patch: $required_path"
  done
}

test_retry_progress_patch_contains_bridge_and_ui_protocol() {
  local version
  local patch
  for version in v0.5 v0.5.2; do
    assert_file "$ROOT_DIR/patches/$version/0001-codex-infinite-retry.patch"
    patch="$(<"$ROOT_DIR/patches/$version/0001-codex-infinite-retry.patch")"
    [[ "$patch" == *"[CODEX_RETRY]"* ]] || fail "$version retry progress marker missing"
    [[ "$patch" == *"onCodexRetryState"* ]] || fail "$version IDEA/WebView retry callback missing"
    [[ "$patch" == *"retryAt"* ]] || fail "$version retry countdown deadline missing"
    [[ "$patch" == *"DAYLY_LIMIT_EXCEEDED"* ]] || fail "$version daily-limit reason classifier missing"
    [[ "$patch" == *"daily usage limit exceeded"* ]] || fail "$version daily-limit message classifier missing"
    [[ "$patch" == *"SAFE_RETRY_CODES"* ]] || fail "$version retry reason code allowlist missing"
    [[ "$patch" != *"sanitizeRetryMessage"* ]] || fail "$version arbitrary retry messages cross the bridge"
  done

  [[ "$patch" == *"phase: 'attempt_started', retryCount: 0"* ]] || \
    fail "v0.5.2 initial attempt state missing"
  [[ "$patch" == *"hasVisibleCodexOutput"* ]] || \
    fail "v0.5.2 visible-output guard missing"
  [[ "$patch" == *"keeps attempt state through history and an empty assistant snapshot"* ]] || \
    fail "v0.5.2 empty assistant regression test missing"
  [[ "$patch" == *"CODEX_SESSION_POLL_INTERVAL_MS"* ]] || \
    fail "v0.5.2 session polling marker missing"
  [[ "$patch" == *"message-tail-assistant-anchor-v1"* ]] || \
    fail "v0.5.2 sparse assistant anchor marker missing"
  [[ "$patch" == *"codex-bounded-history-window-v1"* ]] || \
    fail "v0.5.2 bounded history replay marker missing"
  [[ "$patch" == *"message-tail-sparse-anchor-v2"* ]] || \
    fail "v0.5.2 tail-only sparse anchor marker missing"
  [[ "$patch" == *"getSessionMessagesReplaysExecWrapperInsideBoundedHistory"* ]] || \
    fail "v0.5.2 bounded exec-wrapper regression test missing"
  [[ "$patch" == *"'app-server'"* ]] || \
    fail "v0.5.2 App Server launcher missing"
  [[ "$patch" == *"method: 'thread/fork'"* ]] || \
    fail "v0.5.2 thread/fork request missing"
  [[ "$patch" == *"lastTurnId"* ]] || \
    fail "v0.5.2 stable turn boundary missing"
  [[ "$patch" == *"method: 'thread/delete'"* ]] || \
    fail "v0.5.2 failed branch deletion missing"
  [[ "$patch" == *"Codex SDK 0.148.0 or newer is required"* ]] || \
    fail "v0.5.2 Codex SDK compatibility guard missing"
  [[ "$patch" == *"version = '0.5.2-retry.8'"* ]] || \
    fail "v0.5.2 retry.8 plugin version missing"
  [[ "$patch" == *"canonical-first-user-prompt-v1"* ]] || \
    fail "v0.5.2 canonical first-user-prompt protocol marker missing"
  [[ "$patch" == *"firstUserPrompt"* ]] || \
    fail "v0.5.2 canonical first-user-prompt transport missing"
  [[ "$patch" == *"returnsTheCompleteFirstRealUserPrompt"* ]] || \
    fail "v0.5.2 canonical prompt extractor regression test missing"
  [[ "$patch" == *"latestCodexHistoryPageRetainsTheOriginalFirstPrompt"* ]] || \
    fail "v0.5.2 canonical prompt history regression test missing"
  [[ "$patch" == *"shows, edits, and saves the complete session title"* ]] || \
    fail "v0.5.2 ChatHeader long-title regression test missing"
  [[ "$patch" == *"ai-bridge/services/session-titles-service.test.cjs"* ]] || \
    fail "v0.5.2 session title service regression test missing"
  [[ "$patch" != *"'exec', 'fork'"* ]] || \
    fail "v0.5.2 still contains unreliable exec fork"
}

test_latest_release_has_versioned_retry_inputs() {
  local manifest="$ROOT_DIR/manifests/v0.5.2.json"
  local patch="$ROOT_DIR/patches/v0.5.2/0001-codex-infinite-retry.patch"
  assert_file "$manifest"
  assert_file "$patch"
  jq -e '
    .version == "v0.5.2" and
    .upstream.tag == "v0.5.2" and
    .upstream.commit == "077cccff6707c11796fb0fbd3445b66abd97f83e" and
    .pluginVersion == "0.5.2" and
    .patchedPluginVersion == "0.5.2-retry.8" and
    .artifact == "ccgui-0.5.2-retry.8.zip" and
    (.tests | index("ai-bridge/services/codex/codex-fork.test.js")) != null and
    (.tests | index("ai-bridge/services/session-titles-service.test.cjs")) != null
  ' "$manifest" >/dev/null || fail "v0.5.2 manifest is not pinned to the latest release"
}

test_artifact_verifier_checks_plugin_metadata_and_webview() {
  local verifier
  verifier="$(<"$VERIFY_SCRIPT")"
  for marker in \
    'META-INF/plugin.xml' \
    'html/claude-chat.html' \
    'onCodexRetryState' \
    'codex-retry-status' \
    'CODEX_SESSION_POLL_INTERVAL_MS' \
    'message-tail-assistant-anchor-v1' \
    'message-tail-sparse-anchor-v2' \
    'canonical-first-user-prompt-v1' \
    'readCodexStableBoundary' \
    'createCodexRetryAttempt' \
    'thread/fork' \
    'lastTurnId' \
    'thread/delete' \
    'requiresFork' \
    'publishThreadId' \
    'ended before turn completion' \
    '0.148.0'; do
    [[ "$verifier" == *"$marker"* ]] || fail "artifact verifier does not check: $marker"
  done
}

test_manifest_hashes_cover_patched_existing_files() {
  local version
  local patch
  local manifest
  local created_paths
  local added
  local deleted
  local path
  local created
  local is_created
  for version in v0.5 v0.5.2; do
    patch="$ROOT_DIR/patches/$version/0001-codex-infinite-retry.patch"
    manifest="$ROOT_DIR/manifests/$version.json"
    created_paths="$(git apply --summary "$patch" | sed -n 's/^[[:space:]]*create mode [0-9][0-9]* //p')"

    while IFS=$'\t' read -r added deleted path; do
      [[ -n "$path" ]] || continue
      is_created=false
      while IFS= read -r created; do
        if [[ "$created" == "$path" ]]; then
          is_created=true
          break
        fi
      done <<< "$created_paths"
      [[ "$is_created" == true ]] && continue

      jq -e --arg path "$path" \
        '.sourceHashes[$path] | type == "string" and test("^[0-9a-f]{64}$")' \
        "$manifest" >/dev/null || fail "$version source hash missing for patched file: $path"
    done < <(git apply --numstat "$patch")
  done
}

create_fixture
test_unsupported_version_is_rejected
test_fixture_build_and_verify_succeed
test_commit_mismatch_is_rejected
test_source_hash_mismatch_is_rejected
test_patch_failure_is_rejected
test_v052_patch_contains_every_created_retry_file
test_retry_progress_patch_contains_bridge_and_ui_protocol
test_latest_release_has_versioned_retry_inputs
test_artifact_verifier_checks_plugin_metadata_and_webview
test_manifest_hashes_cover_patched_existing_files
printf 'PASS: patch workflow\n'
