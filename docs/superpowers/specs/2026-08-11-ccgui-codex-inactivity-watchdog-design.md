# CC GUI Codex Inactivity Watchdog Design

## Problem

The v0.5 retry coordinator only starts its fixed 30-second delay after an SDK
attempt rejects. A Codex child can remain alive indefinitely when
`thread.runStreamed()` or the returned async event iterator stops making
progress without rejecting. The bridge then keeps IDEA in its loading state,
and upstream recovery cannot start another attempt.

The observed failure had one `task_started` and one `user_message` event, no
later event or terminal state for more than 45 minutes, and no active upstream
TCP connection. Earlier attempts in the same logical send operation completed
and restarted after approximately 33 seconds, proving that the existing retry
loop was waiting for a terminal signal that never arrived.

## Chosen Approach

Add an inactivity watchdog at the CC GUI Codex bridge layer. The watchdog covers
both creation of the streamed run and every wait for the next SDK event. It is
an inactivity limit, not a total turn duration limit: every received SDK event
starts a fresh interval, so a long-running turn remains valid while it makes
observable progress.

Alternatives were rejected for the following reasons:

- A total attempt timeout would terminate healthy long-running agent work even
  while tools and model events continue.
- Relying on TCP socket inspection would couple the Node bridge to operating
  system details and would not work consistently across platforms.
- Leaving timeout handling to Codex CLI does not solve a CLI or SDK path that
  itself never emits a terminal event.

## Configuration

The default inactivity limit is 300,000 milliseconds (5 minutes). The bridge
reads `CCGUI_CODEX_INACTIVITY_TIMEOUT_MS` as a positive integer so operators can
tune it without rebuilding the plugin. Missing, empty, non-integer, zero, and
negative values use the default.

The existing retry interval remains exactly 30,000 milliseconds and remains
unbounded. The inactivity setting does not change HTTP status classification:
400, 401, and 403 remain terminal; capacity, 429, 5xx, transport failures, and
watchdog expiry are retryable.

## Runtime Flow

1. The coordinator creates a fresh attempt `AbortController`.
2. The message service starts `thread.runStreamed()` under the inactivity
   watchdog.
3. The returned SDK event iterable is wrapped so each `next()` call has a fresh
   inactivity timer.
4. A received event clears its timer before normal event processing continues.
5. On expiry, the watchdog creates a typed retryable inactivity error, aborts
   the current attempt with that error as its reason, and rejects the pending
   operation.
6. The retry coordinator recognizes this internal abort reason as retryable,
   emits the existing retry status, waits 30 seconds, resets attempt-local
   state, and creates a new attempt on the same Codex thread.

The watchdog always clears its timer after success, failure, completion, or
cancellation. It also closes the wrapped iterator when processing exits.

## Cancellation

User cancellation and bridge disposal remain terminal. Only an abort whose
reason is the bridge's typed inactivity error may proceed into the retry path.
This distinction prevents the new logic from turning Stop actions into new
attempts.

## Side Effects

An upstream request may have been accepted even when the bridge receives no
events. Retrying after inactivity therefore retains the existing duplicate
output and duplicate side-effect risk. The README must explicitly include
watchdog retries in that warning.

## Tests

The version-specific patch must add tests proving:

- the default and environment override parsing;
- a never-settling streamed-run creation times out, aborts its attempt, and is
  retried after the existing 30-second delay;
- a never-yielding event iterator behaves the same way;
- every received event resets the inactivity interval;
- completion clears the timer;
- watchdog abort is retryable while user cancellation remains terminal;
- existing HTTP classification and retry lifecycle tests continue to pass.

The repository workflow test, patched bridge tests, full plugin build, outer ZIP
verification, embedded bridge inspection, and SHA-256 verification remain
required before release.
