# CC GUI Codex Retry Progress Design

## Goal

Make every Codex failure visible in CC GUI and distinguish retry waiting from
normal request loading. Retryable failures must show retry progress until a new
attempt starts. Terminal failures must leave loading and follow the existing
error path.

Retry classification and timing are:

- HTTP 429 rate limiting, HTTP 500-599, model capacity, transport failures, and
  Codex stream inactivity are infinitely retryable after a fixed 30-second
  delay.
- A daily usage limit is terminal even when its HTTP status is 429. The bridge
  recognizes the upstream structured reason `DAYLY-LIMIT-EXCEEDED` (including
  Unicode dash variants and the upstream `DAYLY` spelling) and the message
  `daily usage limit exceeded`. Daily-limit evidence takes precedence over
  generic 429 or rate-limit evidence.
- HTTP 400, 401, and 403 remain terminal.
- Other errors remain terminal unless the version-specific classifier already
  marks them retryable.

## User Experience

While a retryable failure is waiting for the next attempt, the existing loading
surface displays a retry state containing:

- the retry number;
- the remaining delay in seconds;
- a safe reason category and short summary.

The countdown is calculated in the WebView from an absolute `retryAt` timestamp
so delayed rendering does not extend the retry delay. When the bridge starts the
next attempt, the retry state is cleared and the UI returns to ordinary loading.
Existing assistant output and tool cards remain visible throughout.

A terminal error never displays retry progress. It ends loading and continues
through the existing error presentation path.

A bare HTTP 429 or `Too Many Requests` remains retryable. This preserves
recovery for transient throttling when an upstream or gateway omits structured
details. Only explicit daily-limit evidence converts a 429 into a terminal
error.

## Protocol

The bridge writes one line per lifecycle event:

```text
[CODEX_RETRY] {"phase":"scheduled","retryCount":1,"delayMs":30000,"retryAt":178...,"reason":{"category":"http_5xx","status":503,"code":"server_error","message":"HTTP 503"}}
[CODEX_RETRY] {"phase":"attempt_started","retryCount":1}
```

Only these fields cross the process boundary:

- `phase`: `scheduled` or `attempt_started`;
- `retryCount`: positive retry count;
- `delayMs` and `retryAt` for `scheduled`;
- `reason.category`: one of `capacity`, `rate_limit`, `http_5xx`, `network`,
  `inactivity`, or `retryable_error`;
- optional numeric `reason.status`;
- optional bounded `reason.code`;
- optional sanitized and bounded `reason.message`.

The bridge must not forward response bodies, stack traces, prompts, credentials,
request headers, or arbitrary nested error objects. Newlines and control
characters are normalized, and summaries are length limited.

`attempt_started` is emitted immediately before each retry attempt invokes the
Codex SDK. The initial attempt does not emit it. A retry scheduled event is
emitted before the 30-second wait begins.

## Components

### Bridge

`codex-retry.js` owns error classification and creates the safe reason payload.
`runCodexTurnWithRetry` exposes both retry scheduling and retry-attempt-start
callbacks. `message-service.js` emits the structured protocol lines.

If the process is cancelled during the delay, no attempt-start event is emitted.
If a retry attempt fails again, a new scheduled event replaces the previous
progress with the incremented retry count.

### IDEA Backend

The Codex output parser recognizes `[CODEX_RETRY]`, validates the JSON shape,
and invokes a dedicated WebView callback. It does not add a chat error message,
end the logical stream, or clear loading for retryable failures.

The backend stores the latest active retry state with the session callback
state. If the WebView is recreated while waiting, the current state is replayed.
`attempt_started`, terminal completion, cancellation, and stream completion
clear the stored retry state.

### WebView

The WebView exposes `window.onCodexRetryState(json)`. A dedicated retry state is
kept separately from the existing `loading` boolean:

- `scheduled` sets retry progress and keeps loading active;
- `attempt_started` clears retry progress and keeps loading active;
- stream end, terminal error, cancellation, session change, or message clear
  clears retry progress.

The existing loading component selects retry progress text when retry state is
present and ordinary loading text otherwise. A one-second local timer updates
the displayed countdown without backend traffic.

## Failure Handling

Malformed retry protocol lines are logged and ignored. They never terminate the
request. Unknown phases and invalid counts/timestamps are rejected.

The existing terminal error path remains authoritative. Retry progress is a
status projection only; it does not decide whether to retry and cannot start an
attempt itself.

If the WebView misses `attempt_started`, the next normal Codex stream activity
also clears stale retry progress. This prevents a successful attempt from
remaining labelled as retrying when JCEF drops one callback.

## Testing

Tests cover:

1. safe reason classification and sanitization for capacity, transient 429,
   5xx, network, inactivity, and fallback retryable failures;
2. terminal classification for 429 responses carrying
   `DAYLY-LIMIT-EXCEEDED`, Unicode dash variants, or
   `daily usage limit exceeded`, including precedence over rate-limit evidence;
3. scheduled and attempt-start callbacks across multiple attempts, including
   cancellation during the delay;
4. exact bridge protocol output without leaking nested error data;
5. IDEA parser validation, forwarding, state replay, and cleanup;
6. WebView retry countdown, retry-to-loading transition, stale-state cleanup,
   terminal errors, and malformed payloads;
7. existing retry policy, bridge tests, WebView tests, Gradle build, versioned
   patch generation, and artifact verification.

## Versioning

This behavior is added only to the pinned CC GUI `v0.5` patch. The artifact is
renamed to `ccgui-0.5-retry.4.zip`; older `retry.1` through `retry.3` artifacts
and their documented behavior remain immutable. Future CC GUI versions require
their own reviewed protocol integration and patch.
