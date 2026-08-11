#!/usr/bin/env bash

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

validate_test_overrides() {
  local override_names=(
    CCGUI_MANIFEST_DIR_OVERRIDE
    CCGUI_UPSTREAM_REPOSITORY_OVERRIDE
    CCGUI_WORK_DIR_OVERRIDE
    CCGUI_DIST_DIR_OVERRIDE
  )
  local name
  for name in "${override_names[@]}"; do
    if [[ -n "${!name:-}" && "${CCGUI_TEST_MODE:-}" != '1' ]]; then
      die "$name is restricted to CCGUI_TEST_MODE=1"
    fi
  done
}

load_manifest() {
  local requested_version="$1"
  require_command jq
  validate_test_overrides

  MANIFEST_DIR="${CCGUI_MANIFEST_DIR_OVERRIDE:-$ROOT_DIR/manifests}"
  MANIFEST="$MANIFEST_DIR/$requested_version.json"
  [[ -n "$requested_version" && -f "$MANIFEST" ]] || \
    die "Unsupported CC GUI version: ${requested_version:-<missing>}"

  jq -e '
    .schemaVersion == 1 and
    (.version | type == "string") and
    (.upstream.repository | type == "string") and
    (.upstream.tag | type == "string") and
    (.upstream.commit | test("^[0-9a-f]{40}$")) and
    (.pluginVersion | type == "string") and
    (.bridgeVersion | type == "string") and
    (.sourceHashes | type == "object" and length > 0) and
    (.patches | type == "array" and length > 0) and
    (.tests | type == "array" and length > 0) and
    (.artifact | type == "string")
  ' "$MANIFEST" >/dev/null || die "Invalid manifest: $MANIFEST"

  VERSION="$(jq -r '.version' "$MANIFEST")"
  [[ "$VERSION" == "$requested_version" ]] || \
    die "Manifest version mismatch: expected $requested_version, found $VERSION"
  UPSTREAM_REPOSITORY="$(jq -r '.upstream.repository' "$MANIFEST")"
  UPSTREAM_TAG="$(jq -r '.upstream.tag' "$MANIFEST")"
  UPSTREAM_COMMIT="$(jq -r '.upstream.commit' "$MANIFEST")"
  PLUGIN_VERSION="$(jq -r '.pluginVersion' "$MANIFEST")"
  BRIDGE_VERSION="$(jq -r '.bridgeVersion' "$MANIFEST")"
  ARTIFACT_NAME="$(jq -r '.artifact' "$MANIFEST")"
  WORK_ROOT="${CCGUI_WORK_DIR_OVERRIDE:-$ROOT_DIR/work}"
  DIST_ROOT="${CCGUI_DIST_DIR_OVERRIDE:-$ROOT_DIR/dist}"
  CHECKOUT="$WORK_ROOT/$VERSION"

  if [[ "${CCGUI_TEST_MODE:-}" == '1' && -n "${CCGUI_UPSTREAM_REPOSITORY_OVERRIDE:-}" ]]; then
    UPSTREAM_REPOSITORY="$CCGUI_UPSTREAM_REPOSITORY_OVERRIDE"
  fi
}

prepare_checkout() {
  require_command git
  mkdir -p "$WORK_ROOT"
  if [[ ! -d "$CHECKOUT/.git" ]]; then
    [[ ! -e "$CHECKOUT" ]] || die "Work path exists but is not a Git checkout: $CHECKOUT"
    git clone --no-checkout "$UPSTREAM_REPOSITORY" "$CHECKOUT"
  fi

  git -C "$CHECKOUT" remote set-url origin "$UPSTREAM_REPOSITORY"
  git -C "$CHECKOUT" fetch --force --tags origin

  local resolved_tag
  resolved_tag="$(git -C "$CHECKOUT" rev-parse "$UPSTREAM_TAG^{commit}" 2>/dev/null)" || \
    die "Upstream tag not found: $UPSTREAM_TAG"
  [[ "$resolved_tag" == "$UPSTREAM_COMMIT" ]] || \
    die "Tag/commit mismatch: $UPSTREAM_TAG resolves to $resolved_tag, expected $UPSTREAM_COMMIT"

  git -C "$CHECKOUT" reset --hard >/dev/null
  git -C "$CHECKOUT" clean -fdx >/dev/null
  git -C "$CHECKOUT" checkout --detach "$UPSTREAM_COMMIT" >/dev/null
  [[ "$(git -C "$CHECKOUT" rev-parse HEAD)" == "$UPSTREAM_COMMIT" ]] || \
    die "Checkout commit mismatch: expected $UPSTREAM_COMMIT"
}

verify_versions_and_hashes() {
  local actual_plugin_version
  local actual_bridge_version
  actual_plugin_version="$(awk -F"'" '/^version = / { print $2; exit }' "$CHECKOUT/build.gradle")"
  [[ "$actual_plugin_version" == "$PLUGIN_VERSION" ]] || \
    die "Plugin version mismatch: expected $PLUGIN_VERSION, found ${actual_plugin_version:-<missing>}"

  actual_bridge_version="$(jq -r '.version' "$CHECKOUT/ai-bridge/package.json")"
  [[ "$actual_bridge_version" == "$BRIDGE_VERSION" ]] || \
    die "Bridge version mismatch: expected $BRIDGE_VERSION, found $actual_bridge_version"

  local path
  local expected_hash
  local actual_hash
  while IFS=$'\t' read -r path expected_hash; do
    [[ -f "$CHECKOUT/$path" ]] || die "Manifest source file missing: $path"
    actual_hash="$(sha256sum "$CHECKOUT/$path" | awk '{print $1}')"
    [[ "$actual_hash" == "$expected_hash" ]] || \
      die "Source hash mismatch: $path expected $expected_hash, found $actual_hash"
  done < <(jq -r '.sourceHashes | to_entries[] | [.key, .value] | @tsv' "$MANIFEST")
}

resolve_patch_path() {
  local patch_path="$1"
  if [[ "$patch_path" = /* ]]; then
    printf '%s\n' "$patch_path"
  else
    printf '%s\n' "$ROOT_DIR/$patch_path"
  fi
}

apply_manifest_patches() {
  local patch_path
  local patch_file
  while IFS= read -r patch_path; do
    patch_file="$(resolve_patch_path "$patch_path")"
    [[ -f "$patch_file" ]] || die "Patch file missing: $patch_path"
    if ! git -C "$CHECKOUT" apply --check --whitespace=error-all "$patch_file"; then
      die "Patch does not apply cleanly: $patch_path"
    fi
    git -C "$CHECKOUT" apply --whitespace=error-all "$patch_file"
  done < <(jq -r '.patches[]' "$MANIFEST")
}

run_bridge_tests() {
  require_command node
  local tests=()
  mapfile -t tests < <(jq -r '.tests[]' "$MANIFEST")
  (cd "$CHECKOUT" && node --test "${tests[@]}")
}

find_single_distribution() {
  local distributions=()
  shopt -s nullglob
  distributions=("$CHECKOUT"/build/distributions/*.zip)
  shopt -u nullglob
  [[ ${#distributions[@]} -eq 1 ]] || \
    die "Expected exactly one Gradle plugin ZIP, found ${#distributions[@]}"
  printf '%s\n' "${distributions[0]}"
}
