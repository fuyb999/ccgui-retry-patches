#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
MANIFEST="$ROOT_DIR/manifests/$VERSION.json"

if [[ -z "$VERSION" || ! -f "$MANIFEST" ]]; then
  printf 'Unsupported CC GUI version: %s\n' "${VERSION:-<missing>}" >&2
  exit 2
fi

printf 'Build workflow is not implemented yet for %s\n' "$VERSION" >&2
exit 1
