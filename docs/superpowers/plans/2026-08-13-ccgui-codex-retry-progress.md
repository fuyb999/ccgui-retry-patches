# CC GUI Codex Retry Progress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show safe Codex retry reason, attempt number, and a 30-second countdown in CC GUI, then restore ordinary loading when the next attempt starts.

**Architecture:** Add a sanitized retry lifecycle object at the retry coordinator, serialize it as a dedicated bridge protocol tag, parse and retain it in the IDEA session layer, and render it as a separate WebView state over the existing loading indicator. Retry classification remains exclusively in the bridge; IDEA and WebView only project status.

**Tech Stack:** Node.js ESM and `node:test`, Java 17 and JUnit, React 18 with TypeScript/Vitest, Gradle IntelliJ plugin build, Bash versioned patch workflow.

---

### Task 1: Safe Bridge Retry Lifecycle

**Files:**
- Modify: `work/v0.5/ai-bridge/services/codex/codex-retry.js`
- Modify: `work/v0.5/ai-bridge/services/codex/codex-retry.test.js`

- [ ] **Step 1: Write failing safe-reason tests**

Add table tests that call `buildCodexRetryReason(error)` for capacity, 429, 503,
network, and inactivity errors. Assert the exact category/status/code/message and
assert that secrets, nested response bodies, newlines, and messages beyond 240
characters do not survive.

```js
const reason = buildCodexRetryReason({
  status: 503,
  code: 'server_error',
  message: 'HTTP 503\nAuthorization: secret',
  response: { body: 'must-not-cross' },
});
assert.deepEqual(reason, {
  category: 'http_5xx',
  status: 503,
  code: 'SERVER_ERROR',
  message: 'HTTP 503 Authorization: [redacted]',
});
assert.equal(JSON.stringify(reason).includes('must-not-cross'), false);
```

Add classification tests for the two HTTP 429 families. A bare 429,
`RATE_LIMIT_EXCEEDED`, and `Too Many Requests` remain retryable. A 429 carrying
structured `reason: 'DAYLY\u2014LIMIT\u2014EXCEEDED'` or the message
`daily usage limit exceeded` is terminal. Assert that daily-limit evidence wins
when transient rate-limit evidence is also present.

- [ ] **Step 2: Run the focused test and confirm RED**

Run: `rtk node --test work/v0.5/ai-bridge/services/codex/codex-retry.test.js`

Expected: failure because `buildCodexRetryReason` is not exported.

- [ ] **Step 3: Implement safe reason construction**

Reuse `collectErrorEvidence` and export `buildCodexRetryReason`. Select categories
in this order: inactivity, capacity, rate limit, HTTP 5xx, network, fallback.
Allow only status, normalized uppercase code, and a single-line 240-character
message with credential-like values redacted.

Normalize structured `reason`, `code`, and `type` identifiers to uppercase
underscore form, including Unicode dash variants. Check explicit daily-limit
codes and messages before any generic 429/rate-limit rule. Do not emit retry
progress for daily-limit failures; throw them through the existing terminal
error path.

- [ ] **Step 4: Write failing attempt-start callback tests**

Extend `runCodexTurnWithRetry` tests with `onAttemptStart`. Assert it is not
called for the initial attempt, is called with `{ retryCount: 1 }` after the
sleep resolves, increments across retries, and is not called when cancellation
rejects the delay.

- [ ] **Step 5: Implement and verify lifecycle callbacks**

Call `onAttemptStart?.({ retryCount })` immediately before retry attempts where
`retryCount > 0`. Keep `onRetry` before the delay and include the safe `reason`,
`delayMs`, and absolute `retryAt`.

Run: `rtk node --test work/v0.5/ai-bridge/services/codex/codex-retry.test.js`

Expected: all retry unit tests pass.

### Task 2: Bridge Protocol Emission

**Files:**
- Modify: `work/v0.5/ai-bridge/services/codex/message-service.js`
- Modify: `work/v0.5/ai-bridge/services/codex/message-service.retry.test.js`

- [ ] **Step 1: Write failing protocol tests**

Capture stdout around `runCodexMessageAttempts`. Assert one exact
`[CODEX_RETRY]` scheduled line appears before the sleep and one attempt-started
line appears after the sleep. Assert the logical stream still emits only one
start and one end.

```js
assert.deepEqual(retryEvents.map(({ phase }) => phase), [
  'scheduled',
  'attempt_started',
]);
assert.equal(retryEvents[0].retryCount, 1);
assert.equal(retryEvents[0].delayMs, 30_000);
```

- [ ] **Step 2: Run the focused test and confirm RED**

Run: `rtk node --test work/v0.5/ai-bridge/services/codex/message-service.retry.test.js`

Expected: no structured retry lines are emitted.

- [ ] **Step 3: Implement protocol emission**

Add `emitCodexRetryState(payload)` which writes only:

```js
process.stdout.write(`[CODEX_RETRY] ${JSON.stringify(payload)}\n`);
```

Wire coordinator `onRetry` to `scheduled`, and `onAttemptStart` to
`attempt_started`. Preserve any injected test callbacks after protocol output.

- [ ] **Step 4: Verify bridge tests**

Run: `rtk node --test work/v0.5/ai-bridge/services/codex/*.test.js`

Expected: all Codex bridge tests pass.

### Task 3: IDEA Parser And Retained State

**Files:**
- Modify: `work/v0.5/src/main/java/com/github/claudecodegui/session/CodexMessageHandler.java`
- Modify: `work/v0.5/src/main/java/com/github/claudecodegui/session/SessionCallbackAdapter.java`
- Modify: `work/v0.5/src/main/java/com/github/claudecodegui/ui/ChatWindowDelegate.java`
- Test: `work/v0.5/src/test/java/com/github/claudecodegui/session/CodexMessageHandlerRetryStateTest.java`
- Test: `work/v0.5/src/test/java/com/github/claudecodegui/session/SessionCallbackAdapterRetryStateTest.java`

- [ ] **Step 1: Write failing parser tests**

Feed scheduled, attempt-started, malformed JSON, invalid phase, invalid count,
and invalid timestamp lines into the Codex handler. Assert valid payloads call a
dedicated callback and malformed payloads are ignored without completing the
stream or adding an error message.

- [ ] **Step 2: Run the focused Java tests and confirm RED**

Run:

```bash
rtk ./gradlew test --tests '*CodexMessageHandlerRetryStateTest' --tests '*SessionCallbackAdapterRetryStateTest'
```

Expected: compilation or assertion failure because retry-state handling does
not exist.

- [ ] **Step 3: Implement validation and forwarding**

Recognize `[CODEX_RETRY] ` before generic status/error parsing. Parse with the
project JSON API into a constrained DTO or validated map. Reject unknown fields
only when they affect required shape; accept only the documented phases and
numeric ranges. Forward the original normalized JSON with:

```java
callbackTarget.callJavaScript("onCodexRetryState", normalizedJson);
```

- [ ] **Step 4: Retain and replay scheduled state**

Store scheduled JSON in `SessionCallbackAdapter`; clear it on attempt-started,
stream end, terminal error, cancellation, and new-session reset. Add replay to
`ChatWindowDelegate` after normal loading/streaming state replay so a recreated
WebView immediately restores retry progress.

- [ ] **Step 5: Verify focused Java tests**

Run the focused Gradle command from Step 2.

Expected: both retry-state test classes pass.

### Task 4: WebView Retry Progress State

**Files:**
- Modify: `work/v0.5/webview/src/global.d.ts`
- Modify: `work/v0.5/webview/src/contexts/MessagesContext.tsx`
- Modify: `work/v0.5/webview/src/hooks/useWindowCallbacks.ts`
- Modify: `work/v0.5/webview/src/hooks/windowCallbacks/registerCallbacks/messageCallbacks.ts`
- Modify: `work/v0.5/webview/src/hooks/windowCallbacks/registerCallbacks/streamingCallbacks.ts`
- Modify: `work/v0.5/webview/src/App.tsx`
- Modify: `work/v0.5/webview/src/components/ChatScreen.tsx`
- Modify: `work/v0.5/webview/src/components/MessageList.tsx`
- Modify: `work/v0.5/webview/src/components/WaitingIndicator.tsx`
- Test: `work/v0.5/webview/src/hooks/windowCallbacks/registerCallbacks/messageCallbacks.test.ts`
- Create: `work/v0.5/webview/src/components/WaitingIndicator.test.tsx`

- [ ] **Step 1: Write failing callback-state tests**

Add the `CodexRetryState` type and test scheduled, attempt-started, malformed,
stream-start stale cleanup, stream-end cleanup, and terminal error cleanup.
Scheduled must set loading true; attempt-started must clear retry state without
setting loading false.

- [ ] **Step 2: Run focused Vitest tests and confirm RED**

Run:

```bash
rtk npm --prefix work/v0.5/webview test -- --run messageCallbacks streamingCallbacks
```

Expected: callback/type failures because retry state does not exist.

- [ ] **Step 3: Implement callback and state cleanup**

Add `retryState`/`setRetryState` in `App.tsx` and callback options. Register
`window.onCodexRetryState`. Clear retry state on the first normal stream
activity after scheduling, `onStreamEnd`, error, cancellation, clear messages,
and session transition.

- [ ] **Step 4: Write failing countdown rendering tests**

Use fake timers with a fixed `retryAt`. Assert the view displays retry number,
safe reason, and `30s`, then `29s`; assert attempt-started restores the ordinary
loading label while keeping the stop control available.

- [ ] **Step 5: Implement the retry loading presentation**

Keep the existing loading layout and controls. Replace only its status text
while `retryState.phase === 'scheduled'`. Use a one-second timer and
`Math.max(0, Math.ceil((retryAt - Date.now()) / 1000))`; do not use viewport
scaled typography or add explanatory UI.

- [ ] **Step 6: Verify WebView tests and build**

Run:

```bash
rtk npm --prefix work/v0.5/webview test -- --run
rtk npm --prefix work/v0.5/webview run build
```

Expected: all WebView tests pass and production build succeeds.

### Task 5: Versioned Patch And Artifact

**Files:**
- Modify: `patches/v0.5/0001-codex-infinite-retry.patch`
- Modify: `manifests/v0.5.json`
- Modify: `README.md`
- Modify: `tests/patch-workflow.test.sh`
- Create: `dist/ccgui-0.5-retry.4.zip`
- Create: `dist/ccgui-0.5-retry.4.zip.sha256`

- [ ] **Step 1: Update workflow expectations to retry.4 and confirm RED**

Change artifact expectations and required patch paths/protocol markers in the
workflow test.

Run: `rtk tests/patch-workflow.test.sh`

Expected: failure until manifest, patch, and artifact metadata are updated.

- [ ] **Step 2: Regenerate the version-specific patch**

Diff the pinned clean `v0.5` source against the tested `work/v0.5` files. Keep
all earlier retry.3 changes plus retry-progress files in the single ordered
v0.5 patch. Update source hashes only for newly patched original files and set
the artifact to `ccgui-0.5-retry.4.zip`.

- [ ] **Step 3: Update documentation**

Document structured retry progress, terminal behavior, countdown semantics,
safe summaries, and the `retry.4` install path/checksum.

- [ ] **Step 4: Run source preparation and all tests**

Run:

```bash
rtk tests/patch-workflow.test.sh
rtk scripts/build.sh v0.5 --prepare-only
```

Expected: workflow and patched upstream tests pass.

- [ ] **Step 5: Build and verify the plugin**

Run:

```bash
rtk scripts/build.sh v0.5
rtk scripts/verify.sh v0.5
```

Expected: Gradle build succeeds, outer and embedded ZIP checks pass, and the
reported artifact is `dist/ccgui-0.5-retry.4.zip`.

- [ ] **Step 6: Commit implementation**

Commit source patch, manifest, tests, docs, checksum, and build scripts without
adding `work/`, `.idea/`, logs, sessions, or credentials.
