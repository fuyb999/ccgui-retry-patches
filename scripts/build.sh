#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"

VERSION_ARG="${1:-}"
MODE="${2:-}"
[[ -z "$MODE" || "$MODE" == '--prepare-only' ]] || die "Unknown build option: $MODE"

require_command sha256sum
load_manifest "$VERSION_ARG"
prepare_checkout
verify_versions_and_hashes
apply_manifest_patches
run_bridge_tests

if [[ "$MODE" == '--prepare-only' ]]; then
  printf 'Prepared and tested %s at %s\n' "$VERSION" "$UPSTREAM_COMMIT"
  exit 0
fi

install_webview_dependencies
(cd "$CHECKOUT/webview" && npm run prebuild)
(cd "$CHECKOUT/webview" && npm test)
(cd "$CHECKOUT" && ./gradlew test)
(cd "$CHECKOUT" && ./gradlew buildPlugin)
distribution="$(find_single_distribution)"
mkdir -p "$DIST_ROOT"
cp "$distribution" "$DIST_ROOT/$ARTIFACT_NAME"
(cd "$DIST_ROOT" && sha256sum "$ARTIFACT_NAME" > "$ARTIFACT_NAME.sha256")
printf 'Built %s\n' "$DIST_ROOT/$ARTIFACT_NAME"
