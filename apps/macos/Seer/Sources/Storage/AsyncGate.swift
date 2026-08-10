import Foundation

/// A cooperative, FIFO mutual-exclusion gate for `async` work.
///
/// Swift actors only serialize access up to their first `await`: once an
/// actor method suspends on awaited I/O, another call into the same actor
/// is free to interleave (actor reentrancy). `AsyncGate` closes that gap by
/// making callers explicitly queue for a turn, in strict first-come,
/// first-served order, so a whole logical operation — including every
/// `await` inside it — runs to completion before the next queued caller is
/// allowed to start.
///
/// Implementation is a plain actor-confined `Bool` plus an ordered array of
/// checked continuations, deliberately avoiding blocking locks/semaphores
/// (which would starve the cooperative thread pool) and avoiding the
/// complexity of continuation-cancellation bookkeeping.
///
/// `acquire()` is intentionally **non-cancellable**: once a caller is
/// queued, Swift task cancellation on that caller does not dequeue it or
/// otherwise let it jump the line. Every `acquire()` is guaranteed to
/// eventually resume exactly once, because every caller calls `release()`
/// on every exit path of its guarded operation (including throwing paths)
/// — so there is nothing to leak. Callers that care about cancellation
/// should check `Task.isCancelled` once `acquire()` returns, before doing
/// any work.
public actor AsyncGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// Suspends until it is this caller's turn (immediately, if the gate is
    /// currently free), then returns holding the gate. Must be paired with
    /// exactly one `release()` call on every exit path of the guarded
    /// operation (normal return or thrown error).
    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    /// Releases the gate, handing it directly to the next queued waiter (if
    /// any) so the gate is never observably free between one operation
    /// finishing and the next starting.
    func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        let next = waiters.removeFirst()
        next.resume()
    }
}
