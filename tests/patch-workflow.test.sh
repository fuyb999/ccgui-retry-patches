#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="$ROOT_DIR/scripts/build.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"
}

test_unsupported_version_is_rejected() {
  local output
  local status
  set +e
  output="$($BUILD_SCRIPT v9.9 2>&1)"
  status=$?
  set -e

  [[ $status -ne 0 ]] || fail 'unsupported version unexpectedly succeeded'
  assert_contains "$output" 'Unsupported CC GUI version: v9.9'
}

test_unsupported_version_is_rejected
printf 'PASS: unsupported version is rejected\n'
