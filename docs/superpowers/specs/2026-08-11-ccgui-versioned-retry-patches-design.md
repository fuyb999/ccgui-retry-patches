# Versioned CC GUI Retry Patches Design

## Status

Approved for implementation on 2026-08-11.

## Goal

Create a standalone Git repository that produces a reproducible patched CC GUI
plugin ZIP for each explicitly supported upstream version. The patched Codex
bridge must keep the IDEA session open and retry retryable turn failures forever
at a fixed 30-second interval.

## Repository And Upstream

The patch repository lives at:

```text
/home/develop/IdeaProjects/ccgui-retry-patches
```

The upstream source repository is:

```text
https://github.com/zhukunpenglinyutong/jetbrains-cc-gui.git
```

The first supported release is pinned exactly as follows:

```text
version: v0.5
commit: 76247b2001c17ff4de28b98458b5e7ed0860962e
installed bridge signature: 0.5:78ffab2e24933e561e68dd81eb396cd2ccc444b44db031230f4471c56726d1c1
```

The installed `message-service.js` and `codex-event-handler.js` SHA-256 values
match the files at upstream tag `v0.5`. This makes `v0.5` a reproducible source
base rather than a reconstruction from the installed plugin.

## Repository Layout

```text
ccgui-retry-patches/
|-- README.md
|-- manifests/
|   `-- v0.5.json
|-- patches/
|   `-- v0.5/
|       `-- 0001-codex-infinite-retry.patch
|-- scripts/
|   |-- build.sh
|   `-- verify.sh
|-- tests/
|   `-- patch-workflow.test.sh
|-- docs/superpowers/specs/
|-- docs/superpowers/plans/
|-- work/                    # ignored generated upstream checkouts
`-- dist/                    # ignored generated plugin ZIPs
```

Only manifests, patches, scripts, tests, and documentation are committed.
Upstream checkouts and built artifacts are generated locally and ignored.

## Version Manifest

Each supported CC GUI release has one JSON manifest. It records:

- patch schema version;
- upstream repository URL;
- exact upstream tag;
- exact upstream commit;
- original SHA-256 for every patched file;
- ordered patch paths;
- expected plugin version;
- expected bridge source version;
- artifact file name.

The build must stop before applying a patch when any tag, commit, version, or
source hash differs from the manifest. Patch fuzz and cross-version fallback are
not allowed. A new upstream release requires a new manifest and a new patch
directory even when its patch happens to be textually identical.

## Retry Behavior

### Retryable failures

The CC GUI Codex bridge retries forever when an SDK event or thrown error
indicates any of the following:

- model capacity, including `model_at_capacity` and
  `Selected model is at capacity`;
- HTTP 429;
- HTTP status 500 through 599;
- transport failures such as connection reset, connection refused, timeout,
  socket closure, DNS failure, or premature stream termination.

The delay is fixed at 30,000 milliseconds between attempts. It does not use
exponential backoff and has no maximum attempt count.

### Non-retryable failures

HTTP 400, 401, and 403 are emitted through the existing CC GUI error path
without another attempt. Other errors remain non-retryable unless a later
version manifest explicitly documents and tests an expanded classification.

### Stream lifecycle

For a retryable failure, the bridge must not emit `[STREAM_END]`, `[SEND_ERROR]`,
or the final failure JSON. The Node bridge process remains alive while waiting.
After a successful turn, the existing completion path emits exactly one
`[STREAM_END]` and one `[MESSAGE_END]`.

The bridge may emit an existing status-message event for retry progress, but it
must not convert the retry into an assistant message or add retry instructions
to conversation history.

### Attempt state

Each attempt gets a fresh `AbortController` and SDK event iterable. The logical
message state and thread identity remain associated with the original CC GUI
send operation. Attempt-local turn flags are reset before the next attempt.

If an initial thread has already reported a thread ID, later attempts continue
on that thread. The retry implementation must not silently switch to a new
conversation.

### Cancellation

User cancellation, bridge process termination, or IDEA session disposal stops
both an in-flight SDK turn and a pending 30-second delay. Cancellation is never
classified as a retryable transport error.

### Partial output and side effects

Retry remains enabled after partial output or tool activity. This intentionally
accepts the same duplicate-output and duplicate-side-effect risk as manually
submitting the request again. The README and release artifact notes must state
this behavior clearly.

The bridge does not attempt to roll back commands, file changes, MCP calls, or
hosted tool activity from a failed attempt.

## Subagent Boundary

This patch handles SDK `turn.failed`, SDK `error`, and thrown request/stream
errors. It does not parse normal conversation text containing
`<subagent_notification>` and does not synthesize prompts instructing a parent
agent to recreate a failed subagent.

That limitation is deliberate: a textual subagent notification is already part
of a successful parent turn, and replaying the original user message is not a
precise reconstruction of the failed subagent operation.

## Source Patch Design

The upstream changes are maintained as a standard unified Git patch rather than
as copied replacement files. The patch should keep classification and waiting
logic in a small Codex retry module, while `message-service.js` remains the
coordinator for the retry loop. `codex-event-handler.js` must preserve the
failure details needed by the coordinator and must not close the stream before
the coordinator decides whether the failure is terminal.

Tests are added to the upstream `ai-bridge` test suite inside the patch so the
patched behavior is tested in the same runtime and module system used by CC GUI.

## Build Pipeline

`scripts/build.sh v0.5` performs these steps:

1. Parse and validate `manifests/v0.5.json` with `jq`.
2. Fetch or refresh the upstream Git repository in `work/`.
3. Check out the exact manifest commit in a clean detached worktree.
4. Verify plugin version, bridge version inputs, and all original file hashes.
5. Run `git apply --check` for the ordered patch list.
6. Apply the patches without fuzz.
7. Run the focused Codex bridge tests.
8. Run the upstream Gradle `buildPlugin` task.
9. Copy the resulting ZIP to the manifest-defined path under `dist/`.
10. Write a SHA-256 checksum beside the artifact.

The produced artifact is named:

```text
dist/ccgui-0.5-retry.1.zip
```

The repository does not overwrite the currently installed IDEA plugin. The ZIP
is installed through IDEA's "Install Plugin from Disk" workflow.

## Verification

The patch must include automated coverage for:

- capacity failure followed by success;
- HTTP 429 followed by success;
- representative HTTP 5xx followed by success;
- representative network error followed by success;
- repeated retryable failures proving no maximum-attempt branch exists;
- fixed-delay invocation through an injectable sleeper;
- 400, 401, and 403 passing through without retry;
- no `[STREAM_END]` or `[SEND_ERROR]` during a retry;
- one final stream end after success;
- cancellation during the wait;
- cancellation during an active turn;
- a non-retryable error retaining the upstream error payload.

The patch workflow tests must also prove that:

- `v0.5` resolves to the pinned commit;
- a modified source hash is rejected;
- an unsupported version is rejected;
- a patch that no longer applies is rejected;
- the expected artifact and checksum are produced by the full build.

## Upgrade Workflow

Supporting a new CC GUI release requires:

1. Add `manifests/vX.Y.json` with a newly verified tag, commit, and source hashes.
2. Create `patches/vX.Y/` from that release's unmodified source.
3. Adapt the retry patch to the new source rather than copying the old patch
   without review.
4. Run the patched upstream tests and the repository workflow tests.
5. Build and inspect `dist/ccgui-X.Y-retry.1.zip`.

Old manifests and patches remain immutable so historical artifacts can be
reproduced.

## Security And Secrets

The repository never copies `~/.codex/auth.json`, `~/.codemoss/config.json`, API
keys, OAuth tokens, IDEA logs, or session JSONL files. Build logs must not print
request headers or environment values containing credentials.

## Non-Goals

- Modifying the separate HTTP retry proxy.
- Automatically installing or restarting IDEA.
- Retrying HTTP 400, 401, or 403.
- Hiding permanent configuration or authentication failures.
- Reconstructing failed subagent tool calls from conversation text.
- Automatically rebasing a patch onto an unsupported CC GUI version.
