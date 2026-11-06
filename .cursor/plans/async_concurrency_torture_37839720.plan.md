---
name: Async concurrency torture
overview: Add one bounded integration test that drives the pool, cancellation, reconnect, and NOTIFY paths harder than the existing sleep overlap, and fix whatever those runs expose.
todos:
  - id: torture-file
    content: Add tests/test_torture.nim with the seven bounded scenarios and wire it into justfile test-run
    status: completed
  - id: fix-failures
    content: Run the torture binary, fix checkout/NOTIFY (or other) bugs it exposes, and confirm just test is green
    status: completed
isProject: false
---

# Async concurrency torture tests

Existing coverage in [`tests/test_pool.nim`](tests/test_pool.nim) starts `POOL_SIZE` `pg_sleep(1)` tasks, runs one shorter query, and only checks that the short query returns before every long task is `done`. [`tests/test_notifies.nim`](tests/test_notifies.nim) is one waiter, one payload, 100ms timeout. Nothing cancels a task, forces the error/reconnect path, or checks that results stay unmixed.

This runtime is one stagelane thread. The useful stress is adversarial interleaving at `waitReadable` / `park`, not OS threads. A second `exec` on the same raw `apgConnection` is undefined in libpq and can abort the process, so the suite stays on the pool and checks out through `exec` / `withConnection`.

## File and budget

Add [`tests/test_torture.nim`](tests/test_torture.nim) and append `test_torture` to the explicit list in [`justfile`](justfile) `test-run` (`test-build` already compiles every `tests/*.nim`). `test-build` globs the directory, so the new file is picked up there.

Each scenario is a `{.flow.}` proc launched with `go` and bounded by `waitFor(..., ms)` so a lost wakeup fails the binary instead of hanging `just test`. Target under about 15 seconds total: many fast queries, `pg_sleep` only where a task must be mid-flight to cancel. Knobs (`poolSize`, `tasks`, timeouts) live at the top of the file.

Failures use `doAssert` with a short message naming the scenario.

## Scenarios

**1. Saturation and completion.** Pool of 4, about 40 tasks, each `SELECT $1::int` with its own value. Every task finishes inside the timeout and reads back its own value. This is the lost-wakeup test for `checkout` / `checkin` (`park` on [`apgPool.waitq`](asyncpg_stagelane/apg_core.nim), `notifyOne` in `checkin`).

**2. One connection in flight.** Same shape, but each task records `pg_backend_pid()`, sleeps a few hundred milliseconds, then clears the pid. A shared set must stay unique for the whole run, and the number of distinct pids must be at most the pool size. Catches a slot checked out twice.

**3. Error storm and reconnect.** Mix `SELECT 1/0` with successful `SELECT n` on a small pool. [`execPoolAsync`](asyncpg_stagelane/apg_core.nim) treats any `CatchableError` as fatal for that slot: `pqfinish`, nil the connection, `checkin`. The next `checkout` calls `connect`. Assert every task ends (error or value), then a follow-up `SELECT 1` works and `SELECT txid_current_if_assigned() IS NULL` is true (no aborted transaction left open). Do not require the backend pid to survive an error; replacement is the contract.

**4. Cancel while holding a connection.** Fill the pool with `pg_sleep` tasks, `cancel` them after they have checked out, wait until they are `cancelled`, then run a normal query. `CancelledError` is a `CatchableError`, so `execPoolAsync`'s `except` should drop the libpq handle and `finally` should `checkin`. The follow-up query must succeed on a clean session.

**5. Cancel while waiting for a slot.** Hold every connection with sleeps, queue extra tasks, `cancel` only the queued ones, then let the holders finish. Cancelled tasks must end `cancelled`. Survivors must all complete. This guards the `busy = true` window in `checkout`: the flag is set before `connect`, and `checkout` itself has no `finally`. A cancel or connect failure there leaks the slot because [`withConnection`](asyncpg_stagelane/apg_core.nim)'s `try` starts only after `checkout` returns. If this hangs or a later query blocks forever, fix `checkout` so a failure after `busy = true` clears the flag and `notifyOne`s.

**6. Transactional increments.** Create a one-row counter. Many `withConnection` bodies run `BEGIN; UPDATE ... SET n = n + 1; COMMIT` on that row. Final `n` equals the task count. Row locks serialize the updates; a lost checkin, a mixed connection, or a commit that never ran shows up as a short count.

**7. NOTIFY delivery under load.** On one dedicated connection: `LISTEN`, register several `notify` waiters, and `sendNotify` distinct payloads from pool tasks while other pool queries run. The connection path in `processPendingNotifications` wakes the first matching waiter and stops. The pool path walks every pool waiter and wakes all of them. Assert one contract for both: each server NOTIFY is delivered to every waiter registered on that channel at send time, payload unchanged, no extras. Fix the connection loop if it only wakes the first waiter. Keep the listener connection busy enough to `pqconsumeInput` (the existing design only pumps NOTIFY from the exec/COPY read loop). Pool `listenNotify` hits a single checkout, so do not use it as the listener in this test.

Out of scope for this pass: concurrent `COPY` (single-connection API, already covered sequentially in [`tests/test_utils.nim`](tests/test_utils.nim)), `close` racing live tasks, and raw double-`exec` on one `apgConnection`.

## Fix policy

Run `just test` (or `just test-build` plus `tests/test_torture` if Postgres is already up). If a scenario fails, fix the driver invariant it names — most likely the `checkout` busy window and connection NOTIFY fan-out — and re-run the torture binary, then the full suite. Leave `just test` green.
