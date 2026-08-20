#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"

require_command sha256sum
require_command unzip
require_command find
load_manifest "${1:-}"

artifact="$DIST_ROOT/$ARTIFACT_NAME"
checksum="$artifact.sha256"
[[ -f "$artifact" ]] || die "Artifact not found: $artifact"
[[ -f "$checksum" ]] || die "Checksum not found: $checksum"

(cd "$DIST_ROOT" && sha256sum -c "$ARTIFACT_NAME.sha256")
unzip -tq "$artifact" >/dev/null || die "Plugin ZIP integrity check failed: $artifact"

temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT
unzip -qq "$artifact" -d "$temp_dir/plugin"

plugin_jars=()
while IFS= read -r candidate; do
  if unzip -p "$candidate" META-INF/plugin.xml >/dev/null 2>&1; then
    plugin_jars+=("$candidate")
  fi
done < <(find "$temp_dir/plugin" -type f -name '*.jar')
[[ ${#plugin_jars[@]} -eq 1 ]] || \
  die "Expected exactly one plugin JAR, found ${#plugin_jars[@]}"
plugin_jar="${plugin_jars[0]}"

plugin_xml="$(unzip -p "$plugin_jar" META-INF/plugin.xml)"
if ! grep -Fq "<version>$PATCHED_PLUGIN_VERSION</version>" <<< "$plugin_xml"; then
  die "Patched plugin version missing from META-INF/plugin.xml: $PATCHED_PLUGIN_VERSION"
fi

webview_html="$(unzip -p "$plugin_jar" html/claude-chat.html)" || \
  die "Embedded WebView missing: html/claude-chat.html"
webview_markers=(onCodexRetryState codex-retry-status)
if [[ "$VERSION" == 'v0.5.2' ]]; then
  webview_markers+=(message-tail-assistant-anchor-v1 message-tail-sparse-anchor-v2 canonical-first-user-prompt-v1)
fi
for marker in "${webview_markers[@]}"; do
  if ! grep -Fq "$marker" <<< "$webview_html"; then
    die "Embedded WebView retry marker missing: $marker"
  fi
done

mapfile -t bridge_archives < <(find "$temp_dir/plugin" -type f -name ai-bridge.zip)
[[ ${#bridge_archives[@]} -eq 1 ]] || \
  die "Expected exactly one embedded ai-bridge.zip, found ${#bridge_archives[@]}"
bridge_archive="${bridge_archives[0]}"
unzip -tq "$bridge_archive" >/dev/null || die "Embedded ai-bridge.zip integrity check failed"

bridge_entries="$(unzip -Z1 "$bridge_archive")"
required_bridge_paths=(
  services/codex/codex-retry.js
  services/codex/message-service.js
  services/codex/codex-event-handler.js
)
if [[ "$VERSION" == 'v0.5.2' ]]; then
  required_bridge_paths+=(services/codex/codex-fork.js)
fi
for required_path in "${required_bridge_paths[@]}"; do
  if ! printf '%s\n' "$bridge_entries" | grep -Eq "(^|/)$required_path$"; then
    die "Embedded bridge file missing: $required_path"
  fi
done

message_service_entry="$(printf '%s\n' "$bridge_entries" | grep -E '(^|/)services/codex/message-service\.js$' | head -n 1)"
[[ -n "$message_service_entry" ]] || die "Embedded bridge message service missing"
message_service="$(unzip -p "$bridge_archive" "$message_service_entry")" || \
  die "Unable to read embedded Codex message service"
if [[ "$VERSION" == 'v0.5.2' ]] && ! grep -Fq 'CODEX_SESSION_POLL_INTERVAL_MS' <<< "$message_service"; then
  die "Embedded Codex session polling marker missing"
fi
if [[ "$VERSION" == 'v0.5.2' ]]; then
  for marker in \
    'readCodexStableBoundary' \
    'createCodexRetryAttempt' \
    'requiresFork' \
    'publishThreadId' \
    'Codex SDK stream ended before turn completion' \
    'Codex SDK 0.148.0 or newer is required'; do
    if ! grep -Fq "$marker" <<< "$message_service"; then
      die "Embedded reliable retry marker missing: $marker"
    fi
  done

  fork_entry="$(printf '%s\n' "$bridge_entries" | grep -E '(^|/)services/codex/codex-fork\.js$' | head -n 1)"
  [[ -n "$fork_entry" ]] || die "Embedded Codex fork adapter missing"
  fork_source="$(unzip -p "$bridge_archive" "$fork_entry")" || \
    die "Unable to read embedded Codex fork adapter"
  for marker in \
    "'app-server'" \
    "method: 'thread/fork'" \
    'lastTurnId' \
    "method: 'thread/delete'"; do
    if ! grep -Fq "$marker" <<< "$fork_source"; then
      die "Embedded Codex App Server fork marker missing: $marker"
    fi
  done
  if grep -Fq "'exec', 'fork'" <<< "$fork_source"; then
    die "Embedded Codex adapter still uses unreliable exec fork"
  fi

  event_handler_entry="$(printf '%s\n' "$bridge_entries" | grep -E '(^|/)services/codex/codex-event-handler\.js$' | head -n 1)"
  [[ -n "$event_handler_entry" ]] || die "Embedded Codex event handler missing"
  event_handler_source="$(unzip -p "$bridge_archive" "$event_handler_entry")" || \
    die "Unable to read embedded Codex event handler"
  if ! grep -Fq 'config.publishThreadId !== false' <<< "$event_handler_source"; then
    die "Embedded Codex event handler publishes disposable retry thread IDs"
  fi

  sdk_definition_entry="$(unzip -Z1 "$plugin_jar" | grep -E '(^|/)SdkDefinition\.class$' | head -n 1)"
  [[ -n "$sdk_definition_entry" ]] || die "Compiled Codex SDK definition missing"
  if ! unzip -p "$plugin_jar" "$sdk_definition_entry" | grep -aFq '0.148.0'; then
    die "Compiled Codex SDK 0.148.0 requirement missing"
  fi
fi

printf 'Verified %s\n' "$artifact"
