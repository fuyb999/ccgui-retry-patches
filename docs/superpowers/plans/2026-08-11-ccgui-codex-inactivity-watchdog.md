# CC GUI Codex Inactivity Watchdog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a stalled Codex SDK stream become a retryable attempt failure while preserving the fixed 30-second infinite retry policy.

**Architecture:** Add typed inactivity primitives to the version-specific Codex retry module and apply them around streamed-run creation and async event iteration in the message service. A watchdog expiry aborts only the current attempt, while the outer logical-operation signal remains the authority for terminal user cancellation.

**Tech Stack:** JavaScript ES modules, Node.js test runner, Git unified patches, Bash build scripts, Gradle IntelliJ plugin packaging.

---

### Task 1: Specify the watchdog behavior

**Files:**
- Create: `docs/superpowers/specs/2026-08-11-ccgui-codex-inactivity-watchdog-design.md`
- Create: `docs/superpowers/plans/2026-08-11-ccgui-codex-inactivity-watchdog.md`

- [ ] **Step 1: Record the diagnosed failure and selected inactivity semantics**

Document the 300,000 ms default, `CCGUI_CODEX_INACTIVITY_TIMEOUT_MS` override,
per-event timer reset, typed internal abort, unchanged 30,000 ms delay, and
unchanged terminal handling for user cancellation and HTTP 400/401/403.

- [ ] **Step 2: Commit the design and plan**

Run:

```bash
rtk git add docs/superpowers/specs/2026-08-11-ccgui-codex-inactivity-watchdog-design.md docs/superpowers/plans/2026-08-11-ccgui-codex-inactivity-watchdog.md
rtk git commit -m "docs: design Codex inactivity watchdog"
```

Expected: one documentation commit with no generated artifact changes.

### Task 2: Add failing watchdog tests

**Files:**
- Modify in generated v0.5 checkout: `ai-bridge/services/codex/codex-retry.test.js`
- Modify in generated v0.5 checkout: `ai-bridge/services/codex/message-service.retry.test.js`

- [ ] **Step 1: Test configuration and event waiting primitives**

Add tests for a wished-for `resolveCodexInactivityTimeoutMs()` API and a
`withCodexInactivityTimeout()` API. Use injected timers so tests explicitly
fire the pending timer and assert that the same typed timeout error both rejects
the wait and becomes `turnAbortController.signal.reason`.

- [ ] **Step 2: Test coordinator behavior**

Add an integration test where the first SDK event stream never yields, the
watchdog fires, the coordinator records one 30,000 ms delay, and the second
attempt succeeds. Assert that an externally aborted logical-operation signal
still rejects without a retry.

- [ ] **Step 3: Verify RED**

Run:

```bash
rtk node --test ai-bridge/services/codex/codex-retry.test.js ai-bridge/services/codex/message-service.retry.test.js
```

Expected: FAIL because the inactivity exports and integration option do not yet
exist.

### Task 3: Implement the watchdog

**Files:**
- Modify in generated v0.5 checkout: `ai-bridge/services/codex/codex-retry.js`
- Modify in generated v0.5 checkout: `ai-bridge/services/codex/message-service.js`

- [ ] **Step 1: Add typed timeout and configuration parsing**

Export `CODEX_INACTIVITY_TIMEOUT_MS`, `CodexInactivityTimeoutError`, and
`resolveCodexInactivityTimeoutMs(value)`. Give the error a stable
`CODEX_STREAM_INACTIVITY_TIMEOUT` code so existing structured error traversal
can classify it as retryable.

- [ ] **Step 2: Add an aborting inactivity race**

Implement `withCodexInactivityTimeout(operation, options)` so it races a Promise
against an injected timer, aborts the current attempt with the typed error on
expiry, and always clears the timer. Do not abort the outer logical-operation
controller.

- [ ] **Step 3: Wrap streamed-run creation and SDK event iteration**

Resolve the timeout once per logical send. Wrap `thread.runStreamed()` and each
`iterator.next()` call. Close the iterator in `finally`. Treat only a
`CodexInactivityTimeoutError` attempt-abort reason as retryable; all other abort
reasons remain terminal.

- [ ] **Step 4: Verify GREEN**

Run the two focused Node test files and confirm all tests pass.

### Task 4: Regenerate the v0.5 patch and documentation

**Files:**
- Modify: `patches/v0.5/0001-codex-infinite-retry.patch`
- Modify: `README.md`

- [ ] **Step 1: Generate the unified patch from the pinned upstream commit**

Run `rtk git diff --binary --full-index` in the generated v0.5 checkout and
replace the version-specific patch with that exact diff. Do not change the
manifest's pinned upstream hashes because they describe unmodified source.

- [ ] **Step 2: Document configuration and operational behavior**

Add the 5-minute default, environment override, inactivity retry flow, and
duplicate-side-effect warning to the README.

- [ ] **Step 3: Run repository and prepared-source verification**

Run:

```bash
rtk bash tests/patch-workflow.test.sh
rtk scripts/build.sh v0.5 --prepare-only
```

Expected: workflow tests and all patched bridge tests pass.

### Task 5: Build, inspect, and commit the release artifact

**Files:**
- Replace: `dist/ccgui-0.5-retry.1.zip`
- Replace: `dist/ccgui-0.5-retry.1.zip.sha256`

- [ ] **Step 1: Build the plugin**

Run `rtk scripts/build.sh v0.5` and require Gradle `buildPlugin` to exit zero.

- [ ] **Step 2: Verify the outer and embedded archives**

Run `rtk scripts/verify.sh v0.5`, inspect the embedded `ai-bridge.zip`, and
confirm the watchdog code and tests are present.

- [ ] **Step 3: Run final repository checks**

Run `rtk git diff --check`, the workflow test, prepared-source tests, SHA-256
verification, and `rtk git status --short`. Leave the unrelated `.idea/`
directory untracked.

- [ ] **Step 4: Commit source-controlled changes**

Commit the patch and documentation. The ignored artifact remains available in
`dist/` with its newly generated checksum.
