# CC GUI Versioned Retry Patches Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reproducible `v0.5` CC GUI plugin ZIP whose Codex bridge retries capacity, HTTP 429, HTTP 5xx, and transport failures forever every 30 seconds while leaving 400, 401, and 403 terminal.

**Architecture:** The repository pins each upstream release in a JSON manifest and applies an ordered unified patch only after commit and source-hash verification. The upstream patch adds a focused retry module, preserves structured SDK failure events in the event handler, and runs each `runStreamed` attempt through a cancellation-aware retry coordinator in `message-service.js`. Shell workflow tests exercise manifest rejection and patch application; patched upstream Node tests exercise classification, lifecycle, retry, and cancellation.

**Tech Stack:** Bash, Git unified patches, `jq`, Node.js built-in test runner, Gradle/JetBrains IntelliJ Platform plugin build.

---

## File Map

- `.gitignore`: exclude generated upstream worktrees and plugin artifacts.
- `manifests/v0.5.json`: pin upstream tag/commit, original source hashes, ordered patches, versions, and output name.
- `patches/v0.5/0001-codex-infinite-retry.patch`: add retry logic and patched-upstream tests.
- `scripts/lib.sh`: shared manifest, checkout, hash, patch, test, and artifact helpers.
- `scripts/build.sh`: prepare exact source, apply patch, run tests, build plugin, and write checksum.
- `scripts/verify.sh`: verify an existing ZIP/checksum and inspect its embedded bridge.
- `tests/patch-workflow.test.sh`: repository-level tests using local fixture repositories.
- `README.md`: supported versions, retry contract, duplicate-side-effect warning, build/install/upgrade instructions.

### Task 1: Repository workflow contract

**Files:**
- Create: `.gitignore`
- Create: `manifests/v0.5.json`
- Create: `tests/patch-workflow.test.sh`

- [ ] **Step 1: Write failing workflow tests**

Create a shell test harness that invokes public script commands and asserts these cases independently:

```bash
assert_fails_with "Unsupported CC GUI version: v9.9" rtk scripts/build.sh v9.9
assert_fails_with "Source hash mismatch" rtk scripts/build.sh v0.5 --prepare-only
assert_fails_with "Patch does not apply cleanly" rtk scripts/build.sh v0.5 --prepare-only
assert_file "dist/ccgui-0.5-retry.1.zip"
assert_file "dist/ccgui-0.5-retry.1.zip.sha256"
```

The test creates disposable local Git fixtures and sets `CCGUI_UPSTREAM_REPOSITORY_OVERRIDE` only for tests; production builds reject an override unless `CCGUI_TEST_MODE=1` is also set.

- [ ] **Step 2: Run the test and verify RED**

Run: `rtk bash tests/patch-workflow.test.sh`

Expected: FAIL because `scripts/build.sh` does not exist.

- [ ] **Step 3: Add the version manifest and ignore generated files**

Use this manifest contract:

```json
{
  "schemaVersion": 1,
  "version": "v0.5",
  "upstream": {
    "repository": "https://github.com/zhukunpenglinyutong/jetbrains-cc-gui.git",
    "tag": "v0.5",
    "commit": "76247b2001c17ff4de28b98458b5e7ed0860962e"
  },
  "pluginVersion": "0.5",
  "bridgeVersion": "1.0.0",
  "sourceHashes": {
    "ai-bridge/services/codex/message-service.js": "63963fb93aebe746278deeeda661034452613d9abb258650d2eb01d90d062f1f",
    "ai-bridge/services/codex/codex-event-handler.js": "a2bdf050089bb2ac8d07554aea469bb9e533ff995b6a17862ac88825743519b5"
  },
  "patches": ["patches/v0.5/0001-codex-infinite-retry.patch"],
  "artifact": "ccgui-0.5-retry.1.zip"
}
```

Ignore only generated trees:

```gitignore
/work/
/dist/
```

- [ ] **Step 4: Commit the RED contract**

```bash
rtk git add .gitignore manifests/v0.5.json tests/patch-workflow.test.sh
rtk git commit -m "test: define versioned patch workflow"
```

### Task 2: Retry classifier and abortable delay

**Files:**
- Create in upstream patch: `ai-bridge/services/codex/codex-retry.js`
- Create in upstream patch: `ai-bridge/services/codex/codex-retry.test.js`

- [ ] **Step 1: Write classifier tests first**

Cover exact structured and textual forms:

```js
for (const error of [
  { status: 429 }, { statusCode: 500 }, { status: 502 }, { httpStatus: 599 },
  { code: 'model_at_capacity' }, new Error('Selected model is at capacity'),
  Object.assign(new Error('fetch failed'), { code: 'ECONNRESET' }),
  new Error('socket closed before the response completed'),
]) assert.equal(isRetryableCodexError(error), true);

for (const status of [400, 401, 403]) {
  assert.equal(isRetryableCodexError({ status }), false);
  assert.equal(isRetryableCodexError(new Error(`HTTP ${status}`)), false);
}
assert.equal(isRetryableCodexError(new Error('invalid request')), false);
```

Add fake-timer-free delay tests that inject `setTimer/clearTimer`, assert the requested value is exactly `30000`, and abort the supplied signal to assert an `AbortError` rejection.

- [ ] **Step 2: Run the focused test and verify RED**

Run: `rtk node --test ai-bridge/services/codex/codex-retry.test.js`

Expected: FAIL with `ERR_MODULE_NOT_FOUND` for `codex-retry.js`.

- [ ] **Step 3: Implement the minimal retry primitives**

Export these stable APIs:

```js
export const CODEX_RETRY_DELAY_MS = 30_000;
export class CodexTurnFailure extends Error {
  constructor(message, details) {
    super(message, details instanceof Error ? { cause: details } : undefined);
    this.name = 'CodexTurnFailure';
    this.details = details;
  }
}
export function isRetryableCodexError(error) { /* structured walk, terminal-status precedence, then message/code checks */ }
export function abortableDelay(ms, signal, timers = globalThis) { /* timer plus once-only abort listener */ }
export function resetCodexAttemptState(state) { /* reset turn-local flags and usage, preserve thread/output identity */ }
```

Classification must inspect nested `error`, `cause`, `details`, and `response` objects without looping on cyclic objects. Explicit 400/401/403 evidence wins over broad transport text; retry evidence is limited to capacity, 429, 500-599, known network codes, and stream/network failure phrases.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run: `rtk node --test ai-bridge/services/codex/codex-retry.test.js`

Expected: all classifier and delay tests PASS.

### Task 3: Preserve SDK failure details

**Files:**
- Modify in upstream patch: `ai-bridge/services/codex/codex-event-handler.js`
- Modify in upstream patch: `ai-bridge/services/codex/codex-event-handler.test.js`

- [ ] **Step 1: Write failing event-handler tests**

For both `turn.failed` and `error`, assert rejection is a `CodexTurnFailure`, retains the original event in `.details`, and does not invoke `onTurnFailed`:

```js
await assert.rejects(
  processCodexEventStream(eventsFrom([{ type: 'turn.failed', error: { message: 'HTTP 502', status: 502 } }]), state, config),
  (error) => error instanceof CodexTurnFailure && error.details.error.status === 502,
);
assert.equal(turnFailedCalls, 0);
```

Keep the existing command-denial abort suppression tests green.

- [ ] **Step 2: Verify RED**

Run: `rtk node --test ai-bridge/services/codex/codex-event-handler.test.js`

Expected: FAIL because plain `Error` is thrown and `onTurnFailed` closes the stream.

- [ ] **Step 3: Throw structured failures without closing the stream**

Import `CodexTurnFailure`; replace both failure branches with:

```js
console.error('[DEBUG] Turn failed:', errorMsg);
throw new CodexTurnFailure(errorMsg, event);
```

and:

```js
console.error('[DEBUG] Codex error:', generalError);
throw new CodexTurnFailure(generalError, event);
```

Remove `onTurnFailed` invocation so only the outer coordinator decides whether the logical stream is terminal.

- [ ] **Step 4: Verify GREEN**

Run: `rtk node --test ai-bridge/services/codex/codex-event-handler.test.js`

Expected: all event-handler tests PASS.

### Task 4: Infinite turn coordinator

**Files:**
- Modify in upstream patch: `ai-bridge/services/codex/codex-retry.js`
- Modify in upstream patch: `ai-bridge/services/codex/codex-retry.test.js`

- [ ] **Step 1: Write failing coordinator tests**

Exercise real async iteration through injected `runAttempt`:

```js
const failures = [429, 500, 502, 503, 599, 429, 502];
const result = await runCodexTurnWithRetry({
  state,
  signal: new AbortController().signal,
  runAttempt: async ({ turnAbortController }) => {
    const status = failures.shift();
    if (status) throw new CodexTurnFailure(`HTTP ${status}`, { status });
    return 'done';
  },
  sleep: async (ms) => delays.push(ms),
});
assert.equal(result, 'done');
assert.deepEqual(delays, Array(7).fill(30_000));
```

Also assert: non-retryable 400/401/403 make one attempt; retry callback fires without a terminal callback; abort during sleep rejects; abort during an active attempt aborts the fresh attempt controller; each attempt receives a different controller; partial state collections and `currentThreadId` survive reset.

- [ ] **Step 2: Verify RED**

Run: `rtk node --test ai-bridge/services/codex/codex-retry.test.js`

Expected: FAIL because `runCodexTurnWithRetry` is not exported.

- [ ] **Step 3: Implement the unbounded loop**

Use no maximum-attempt variable or branch:

```js
export async function runCodexTurnWithRetry(options) {
  let retryCount = 0;
  while (true) {
    const turnAbortController = new AbortController();
    const unlink = linkAbortSignal(options.signal, turnAbortController);
    try {
      return await options.runAttempt({ turnAbortController, retryCount });
    } catch (error) {
      if (options.signal?.aborted || turnAbortController.signal.aborted || !isRetryableCodexError(error)) throw error;
      retryCount += 1;
      options.onRetry?.({ error, retryCount, delayMs: CODEX_RETRY_DELAY_MS });
      await (options.sleep || abortableDelay)(CODEX_RETRY_DELAY_MS, options.signal);
      resetCodexAttemptState(options.state);
    } finally {
      unlink();
    }
  }
}
```

Ensure the outer abort link remains installed during `runAttempt`, and the sleep uses the logical-operation signal rather than the completed attempt controller.

- [ ] **Step 4: Verify GREEN**

Run: `rtk node --test ai-bridge/services/codex/codex-retry.test.js`

Expected: all retry coordinator tests PASS.

### Task 5: Integrate the coordinator with `sendMessage`

**Files:**
- Modify in upstream patch: `ai-bridge/services/codex/message-service.js`
- Modify in upstream patch: `ai-bridge/services/codex/codex-retry.test.js`

- [ ] **Step 1: Add a failing lifecycle integration test**

Extract an injectable `runCodexMessageAttempts` helper and test a 503-then-success sequence. Capture protocol output and assert zero `[STREAM_END]`/`[SEND_ERROR]` before success, one logical `[STREAM_START]`, one final `[STREAM_END]`, and the same thread object/input on both attempts.

- [ ] **Step 2: Verify RED**

Run: `rtk node --test ai-bridge/services/codex/codex-retry.test.js`

Expected: FAIL because message-service still creates one controller and makes one `runStreamed` call.

- [ ] **Step 3: Route attempts through the retry coordinator**

Create one logical `AbortController`, call `thread.runStreamed` inside `runCodexTurnWithRetry`, pass each fresh attempt controller into `processCodexEventStream`, and emit retry progress only as an existing status event:

```js
onRetry: ({ retryCount, delayMs, error }) => {
  const reason = error?.message || String(error);
  emitStatusMessage(emitMessage, `Codex request failed (${reason}); retry ${retryCount} in ${delayMs / 1000}s`);
}
```

Do not emit `[STREAM_END]`, `[SEND_ERROR]`, `[MESSAGE_END]`, or a final JSON error while retrying. Remove `onTurnFailed`; retain `onTurnCompleted: emitStreamEndOnce`. Reuse `thread`, `runInput`, logical state, and its discovered `currentThreadId`; do not synthesize messages or inspect `<subagent_notification>` text.

- [ ] **Step 4: Run all patched bridge tests**

Run: `rtk node --test ai-bridge/services/codex/codex-retry.test.js ai-bridge/services/codex/codex-event-handler.test.js`

Expected: all tests PASS with no warnings or unhandled rejections.

### Task 6: Capture the version-specific unified patch

**Files:**
- Create: `patches/v0.5/0001-codex-infinite-retry.patch`

- [ ] **Step 1: Generate the patch from the pristine pinned checkout**

```bash
rtk git -C work/v0.5 diff --binary -- ai-bridge/services/codex/message-service.js ai-bridge/services/codex/codex-event-handler.js ai-bridge/services/codex/codex-event-handler.test.js ai-bridge/services/codex/codex-retry.js ai-bridge/services/codex/codex-retry.test.js > patches/v0.5/0001-codex-infinite-retry.patch
```

- [ ] **Step 2: Verify exact applicability**

Run: `rtk git -C /tmp/ccgui-v0.5-clean apply --check --whitespace=error-all patches/v0.5/0001-codex-infinite-retry.patch`

Expected: exit 0 with no output.

- [ ] **Step 3: Commit the patch behavior**

```bash
rtk git add patches/v0.5/0001-codex-infinite-retry.patch
rtk git commit -m "feat: add v0.5 Codex infinite retry patch"
```

### Task 7: Build and verification scripts

**Files:**
- Create: `scripts/lib.sh`
- Create: `scripts/build.sh`
- Create: `scripts/verify.sh`
- Modify: `tests/patch-workflow.test.sh`

- [ ] **Step 1: Run the existing workflow test and confirm it is still RED**

Run: `rtk bash tests/patch-workflow.test.sh`

Expected: FAIL because the build scripts are absent.

- [ ] **Step 2: Implement strict preparation in `scripts/lib.sh`**

Implement `load_manifest`, `prepare_checkout`, `verify_source_hashes`, `apply_manifest_patches`, `run_bridge_tests`, and `find_single_distribution`. Enforce `schemaVersion == 1`, version equality, exact annotated/lightweight tag commit, exact checkout HEAD, JSON package version, Gradle project version, every original SHA-256, ordered `git apply --check --whitespace=error-all`, and then `git apply --whitespace=error-all`.

- [ ] **Step 3: Implement `scripts/build.sh`**

The public command is:

```bash
rtk scripts/build.sh v0.5
```

It prepares `work/v0.5`, applies patches, runs both patched Node test files, executes `rtk ./gradlew buildPlugin`, copies the single distribution ZIP to `dist/ccgui-0.5-retry.1.zip`, and writes `sha256sum` output to `dist/ccgui-0.5-retry.1.zip.sha256`. `--prepare-only` stops after patched tests and is used for fast negative workflow cases.

- [ ] **Step 4: Implement `scripts/verify.sh`**

Verify checksum, outer plugin ZIP integrity, embedded `ai-bridge.zip` integrity, and presence of `services/codex/codex-retry.js`, `message-service.js`, and `codex-event-handler.js` in the bridge archive. Reject artifact names not equal to the manifest value.

- [ ] **Step 5: Run workflow tests and verify GREEN**

Run: `rtk bash tests/patch-workflow.test.sh`

Expected: all workflow cases PASS, including unsupported version, tag/commit mismatch, source-hash mismatch, rejected patch, and fixture artifact/checksum production.

- [ ] **Step 6: Commit the build system**

```bash
rtk git add scripts tests manifests/v0.5.json .gitignore
rtk git commit -m "build: add reproducible CC GUI patch pipeline"
```

### Task 8: Documentation and real artifact verification

**Files:**
- Create: `README.md`

- [ ] **Step 1: Document operation and risk**

Document exact commands, prerequisites (`git`, `jq`, Node.js, JDK 17, `unzip`, network access), supported-version table, IDEA “Install Plugin from Disk”, and new-version workflow. State prominently that retries are infinite at fixed 30-second intervals; 400/401/403 are terminal; capacity/429/5xx/network failures retry; partial output and tool actions may be duplicated; the patch cannot reconstruct textual failed-subagent notifications; cancellation is process termination or an in-flight abort.

- [ ] **Step 2: Build the real pinned artifact**

Run: `rtk scripts/build.sh v0.5`

Expected: patched Node tests PASS, Gradle `buildPlugin` succeeds, and `dist/ccgui-0.5-retry.1.zip` plus checksum exist.

- [ ] **Step 3: Verify the real artifact**

Run: `rtk scripts/verify.sh v0.5`

Expected: checksum and both ZIP integrity checks PASS; embedded retry source is found.

- [ ] **Step 4: Run final repository checks**

```bash
rtk bash tests/patch-workflow.test.sh
rtk git diff --check
rtk git status --short
```

Expected: tests PASS, no whitespace errors, and only intended documentation/source changes remain.

- [ ] **Step 5: Commit documentation**

```bash
rtk git add README.md docs/superpowers/plans/2026-08-11-ccgui-versioned-retry-patches.md
rtk git commit -m "docs: add retry patch build and install guide"
```
