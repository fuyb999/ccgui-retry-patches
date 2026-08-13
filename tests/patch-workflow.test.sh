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
    '    mkdir -p "$package_dir/ccgui"' \
    '    (cd ai-bridge && zip -qr "$package_dir/ccgui/ai-bridge.zip" .)' \
    '    (cd "$package_dir" && zip -qr "$OLDPWD/build/distributions/ccgui-0.5.zip" ccgui)' \
    '    rm -rf "$package_dir"' \
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

  printf "export const retryEnabled = true;\n" > "$FIXTURE_REPO/ai-bridge/services/codex/message-service.js"
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

test_retry_progress_patch_contains_bridge_and_ui_protocol() {
  assert_file "$ROOT_DIR/patches/v0.5/0001-codex-infinite-retry.patch"
  local patch
  patch="$(<"$ROOT_DIR/patches/v0.5/0001-codex-infinite-retry.patch")"
  [[ "$patch" == *"[CODEX_RETRY]"* ]] || fail "retry progress marker missing from versioned patch"
  [[ "$patch" == *"onCodexRetryState"* ]] || fail "IDEA/WebView retry callback missing from versioned patch"
  [[ "$patch" == *"retryAt"* ]] || fail "retry countdown deadline missing from versioned patch"
  [[ "$patch" == *"DAYLY_LIMIT_EXCEEDED"* ]] || fail "daily-limit reason classifier missing from versioned patch"
  [[ "$patch" == *"daily usage limit exceeded"* ]] || fail "daily-limit message classifier missing from versioned patch"
  [[ "$patch" == *"SAFE_RETRY_CODES"* ]] || fail "retry reason code allowlist missing from versioned patch"
  [[ "$patch" != *"sanitizeRetryMessage"* ]] || fail "arbitrary upstream retry messages must not cross the bridge"
}

test_manifest_hashes_cover_patched_existing_files() {
  local patch="$ROOT_DIR/patches/v0.5/0001-codex-infinite-retry.patch"
  local manifest="$ROOT_DIR/manifests/v0.5.json"
  local created_paths
  local added
  local deleted
  local path
  local created
  local is_created
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
      "$manifest" >/dev/null || fail "source hash missing for patched file: $path"
  done < <(git apply --numstat "$patch")
}

create_fixture
test_unsupported_version_is_rejected
test_fixture_build_and_verify_succeed
test_commit_mismatch_is_rejected
test_source_hash_mismatch_is_rejected
test_patch_failure_is_rejected
test_retry_progress_patch_contains_bridge_and_ui_protocol
test_manifest_hashes_cover_patched_existing_files
printf 'PASS: patch workflow\n'
