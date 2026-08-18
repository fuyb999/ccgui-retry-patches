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
  webview_markers+=(message-tail-assistant-anchor-v1 message-tail-sparse-anchor-v2)
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
for required_path in \
  services/codex/codex-retry.js \
  services/codex/message-service.js \
  services/codex/codex-event-handler.js; do
  if ! printf '%s\n' "$bridge_entries" | grep -Eq "(^|/)$required_path$"; then
    die "Embedded bridge file missing: $required_path"
  fi
done

message_service_entry="$(printf '%s\n' "$bridge_entries" | grep -E '(^|/)services/codex/message-service\.js$' | head -n 1)"
[[ -n "$message_service_entry" ]] || die "Embedded bridge message service missing"
message_service="$(unzip -p "$bridge_archive" "$message_service_entry")" || \
  die "Unable to read embedded Codex message service"
if ! grep -Fq 'CODEX_SESSION_POLL_INTERVAL_MS' <<< "$message_service"; then
  die "Embedded Codex session polling marker missing"
fi

printf 'Verified %s\n' "$artifact"
