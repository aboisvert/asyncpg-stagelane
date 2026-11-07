# Why `apgSharedPool` requires `-d:flowThreads`

`asyncpg_stagelane/apg_shared_pool.nim` only compiles with
`--threads:on --mm:atomicArc -d:flowThreads`. This note explains why.
(References are to `deps/stagelane/src/stagelane/`.)

## What the flag changes in stagelane

Without the flag, stagelane is single-threaded. Each thread has its own
`{.threadvar.}` scheduler, and nothing is built to be touched from another
thread. With `-d:flowThreads` (`core.nim:16`), the `when flowThreads:` branches
switch on four things:

1. **`WaitQueue` gets a `Lock`** (`core.nim:53`). `park`, `notifyOne`,
   `notifyAll` and `epochOf` are guarded by it. Without the flag, the queue is
   an unsynchronized intrusive list.
2. **Each scheduler gets a cross-thread part (`SchedShared`).** It holds a
   mailbox (an MPSC queue with `mhead`/`mtail`) and a `wake` event registered
   in that thread's selector (`sched.nim`, `initShared`).
3. **Wakeups are routed to the owning thread.** Every parked continuation
   records its scheduler (`t.sched`, `sched.nim:693`). When
   `notifyOne`/`notifyAll` runs on thread B for a waiter parked on thread A, it
   posts the continuation into A's mailbox and triggers A's wake event.
   `runLoop` drains that inbox (`drainInbox`) before running ready tasks.
   `cancel` uses the same mechanism (`CancelReq`, `sched.nim:777`).
4. **The idle loop is allowed to block** until a timer, an fd or another thread
   wakes it, instead of treating "nothing ready" as idle or deadlocked.

## Why `apg_shared_pool` depends on it

The pool's core operation is a task on thread A parking in `checkout` while a
task on thread B calls `checkin`, which calls `notifyOne(pool.waitq)`.

- **Without the flag:** the waiter would be resumed on thread B's scheduler. A
  continuation that belongs to A would run on B, the unlocked `WaitQueue` would
  race, and A might sleep forever in its selector. `epochOf`/`parkSince`, which
  the pool uses to avoid lost wakeups, also depend on the queue's lock for the
  epoch check and the park to be atomic.
- **`close(pool)` has the same need:** its `notifyAll` must wake waiters on
  every thread.
- **`NotifyWait` has it too:** a NOTIFY delivered by whichever thread's `exec`
  read it must wake the `waitNotify` caller on its own thread.

## Why `--threads:on --mm:atomicArc` come with it

`core.nim:20-21` asserts both. Tasks, `WaitQueue`s and `Frame`s are
reference-counted objects shared between threads. Plain ARC/ORC counts
references non-atomically, so they would be corrupted. That is the reason for
`atomicArc` specifically.

## Why the `{.error.}` is there

Without the flag the module would compile, and it would silently misbehave:
lost wakeups, continuations run on the wrong thread, and data races on the
`WaitQueue`. The `when not defined(flowThreads): {.error.}` at the top of
`apg_shared_pool.nim` turns that into an immediate compile error. This also
matches how stagelane guards `stagelane/exec` (`exec.nim:10`).

## What it does not need

libpq itself has no connection to the flag. libpq's thread-safety is checked
separately, at runtime, by `pqisthreadsafe()` in `newSharedPool`. The plain
`apgPool` doesn't need the flag, because it never leaves its thread.
