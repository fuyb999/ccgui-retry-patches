# CC GUI Versioned Codex Retry Patches

This repository builds version-specific CC GUI plugin ZIPs with a patched Codex
bridge. A supported release is pinned to an exact upstream tag, commit, source
hash set, and ordered Git patch list. Patches are never applied across versions.

## Supported Versions

| CC GUI | Upstream commit | Patch artifact |
| --- | --- | --- |
| `v0.5` | `76247b2001c17ff4de28b98458b5e7ed0860962e` | `dist/ccgui-0.5-retry.4.zip` |

## Retry Policy

The patched bridge keeps the logical IDEA stream open and retries forever at a
fixed 30-second interval for:

- model capacity failures, including `model_at_capacity` and
  `Selected model is at capacity`;
- transient HTTP 429 rate limiting, including bare 429 and `Too Many Requests`;
- HTTP 500 through 599, including 502 and 503;
- connection, DNS, timeout, socket, fetch, and premature stream failures.

HTTP 400, 401, and 403 are terminal and follow the existing CC GUI error path.
An HTTP 429 is also terminal when it explicitly reports the daily usage limit
through `reason=DAYLY-LIMIT-EXCEEDED` (the upstream spelling, including Unicode
dash variants) or `message=daily usage limit exceeded`. Explicit daily-limit
evidence takes precedence over generic rate-limit evidence. Other errors are
terminal unless a version-specific patch explicitly adds and tests them.

Every retry creates a fresh turn `AbortController` and SDK event stream while
reusing the same thread object, input, and logical output state. Retry progress
is emitted as a dedicated `[CODEX_RETRY]` event. The event is sanitized before
crossing the IDEA/WebView boundary and contains only a retry phase, attempt
number, absolute retry deadline, and an allowlisted category/status/code reason.
Arbitrary upstream error messages never cross the retry progress bridge. While waiting,
CC GUI shows the retry number, safe reason, and a live 30-second countdown. The
next attempt clears retry progress and restores ordinary loading. The bridge does not emit `[STREAM_END]`,
`[SEND_ERROR]`, or a final failure JSON between retry attempts.

The two lifecycle payloads are:

```text
[CODEX_RETRY] {"phase":"scheduled","retryCount":1,"delayMs":30000,"retryAt":...,"reason":{"category":"http_5xx","status":503,"code":"SERVER_ERROR"}}
[CODEX_RETRY] {"phase":"attempt_started","retryCount":1}
```

Malformed payloads and unknown reason categories are ignored. Terminal 400, 401,
403, and daily-limit 429 errors clear retry progress and follow the existing
error display path.

The bridge also retries when the Codex SDK produces no event for 10 minutes.
This inactivity watchdog covers every wait for the next SDK event. Each received
event starts a fresh interval, so it does not impose a total duration limit on
active turns. Set `CCGUI_CODEX_INACTIVITY_TIMEOUT_MS` to a positive integer to
override the 600,000 ms default. Invalid, zero, and negative values use the
default.

Stopping the CC GUI task terminates the bridge process, which also terminates an
active request or pending delay. In-process abort signals cancel both an active
attempt and a pending delay and are never retried.

## Side-Effect Warning

Retries, including inactivity retries, remain enabled after partial assistant
output or tool activity. A failed or apparently inactive attempt may already
have run commands, edited files, called MCP tools, or caused other external side
effects. A later attempt can repeat those effects. The bridge does not roll
anything back.

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
7. generates the ignored WebView version source using the upstream `prebuild` script;
8. runs the complete WebView test suite and test TypeScript check;
9. runs the Gradle test suite;
10. runs Gradle `buildPlugin`;
11. writes the renamed plugin ZIP and SHA-256 checksum under `dist/`.

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
4. Select `dist/ccgui-0.5-retry.4.zip`.
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

The previously installed standalone HTTP retry proxy and its user systemd unit
are preserved separately under `backups/codex-retry-proxy/`. They are not used
by the source-patched plugin build.
