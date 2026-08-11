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

printf 'Verified %s\n' "$artifact"
