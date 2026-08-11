# CC GUI Versioned Codex Retry Patches

This repository builds version-specific CC GUI plugin ZIPs with a patched Codex
bridge. A supported release is pinned to an exact upstream tag, commit, source
hash set, and ordered Git patch list. Patches are never applied across versions.

## Supported Versions

| CC GUI | Upstream commit | Patch artifact |
| --- | --- | --- |
| `v0.5` | `76247b2001c17ff4de28b98458b5e7ed0860962e` | `dist/ccgui-0.5-retry.1.zip` |

## Retry Policy

The patched bridge keeps the logical IDEA stream open and retries forever at a
fixed 30-second interval for:

- model capacity failures, including `model_at_capacity` and
  `Selected model is at capacity`;
- HTTP 429;
- HTTP 500 through 599, including 502 and 503;
- connection, DNS, timeout, socket, fetch, and premature stream failures.

HTTP 400, 401, and 403 are terminal and follow the existing CC GUI error path.
Other errors are terminal unless a version-specific patch explicitly adds and
tests them.

Every retry creates a fresh turn `AbortController` and SDK event stream while
reusing the same thread object, input, and logical output state. Retry progress
is emitted as a status event. The bridge does not emit `[STREAM_END]`,
`[SEND_ERROR]`, or a final failure JSON between retry attempts.

Stopping the CC GUI task terminates the bridge process, which also terminates an
active request or pending delay. In-process abort signals cancel both an active
attempt and a pending delay and are never retried.

## Side-Effect Warning

Retries remain enabled after partial assistant output or tool activity. A failed
attempt may already have run commands, edited files, called MCP tools, or caused
other external side effects. A later attempt can repeat those effects. The
bridge does not roll anything back.

This patch handles SDK failures and thrown request/stream errors. It does not
parse textual `<subagent_notification>` content or recreate a failed subagent
from a synthetic prompt.

## Prerequisites

- Git
- `jq`
- Node.js and npm
- JDK 17
- `unzip` and `sha256sum`
- network access for the pinned upstream source and Gradle dependencies

## Build

From this repository:

```bash
rtk scripts/build.sh v0.5
```

The build performs all of the following before producing an artifact:

1. validates the manifest schema and supported version;
2. resolves the upstream tag and requires the exact pinned commit;
3. verifies plugin, bridge, and original patched-file hashes;
4. applies each patch with `git apply --check --whitespace=error-all`;
5. runs the patched Codex Node tests;
6. installs locked webview dependencies with `npm ci` when needed;
7. runs Gradle `buildPlugin`;
8. writes the renamed plugin ZIP and SHA-256 checksum under `dist/`.

Run source preparation and patched tests without Gradle packaging:

```bash
rtk scripts/build.sh v0.5 --prepare-only
```

Verify an existing artifact, checksum, outer plugin ZIP, and embedded bridge:

```bash
rtk scripts/verify.sh v0.5
```

## Install

1. Open IDEA settings.
2. Go to **Plugins**.
3. Open the gear menu and choose **Install Plugin from Disk**.
4. Select `dist/ccgui-0.5-retry.1.zip`.
5. Restart the IDE when prompted.

The scripts never overwrite the currently installed plugin.

## Add A Version

For every new CC GUI version:

1. add `manifests/vX.Y.json` with a newly verified tag, commit, versions, source
   hashes, tests, artifact name, and ordered patch paths;
2. create `patches/vX.Y/` from the unmodified release source;
3. adapt and review the retry patch against that release instead of reusing the
   prior patch without inspection;
4. run the repository workflow test, patched upstream tests, full build, and
   artifact verification;
5. keep older manifests and patch directories unchanged.

Generated source checkouts under `work/` and artifacts under `dist/` are ignored
by Git. Authentication files, API keys, IDEA logs, and Codex session files must
never be added to this repository.
