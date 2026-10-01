# F08 worker listener retirement evidence — 2026-10-01

## Hosted failure

GitHub Actions run `36813872693`, server shard 3, job `110214595862` failed
`test_worker_restart_removes_only_its_verified_stale_socket`. The replacement
worker reported `worker_unavailable` while binding, and fixture cleanup found the
old directory non-empty. The public failure wrapper did not retain the inner
bind exception type or site, so this does not prove one exclusive hosted cause.

## Source-backed mechanism and repair

Linux [`close(2)`](https://man7.org/linux/man-pages/man2/close.2.html) documents
that a thread blocked in I/O may retain the open file description and complete
the operation after another thread closes the descriptor. Relying on a
cross-thread listener close to wake `accept()` therefore provides no bounded
worker shutdown guarantee. This is a source-backed production defect and a
strong explanation for the hosted symptom; the redacted inner bind error keeps
the exact hosted causal chain unproved.

`AiWorkerServer` now gives its listening socket a 250 ms accept timeout. Each
serving thread snapshots the listener once after bind and continues only while
that exact listener remains current. Retirement therefore exits without
contacting the filesystem socket path or a successor listener. An accepted
stream is also closed without dispatch if retirement wins after `accept()`.

## Focused evidence

- The initial restart, stale-socket, and round-trip target set passed: 3 tests.
- The pre-successor-race F08 IPC file passed: 11 tests.
- The final F08 IPC file passed: 12 tests, with one existing Linux-only host
  acceptance skipped on macOS.
- Root independently ran the final file with the same result: 12 passed and one
  explicit Linux dedicated-user acceptance skip.
- The added deterministic successor regression makes the old listener time out
  after replacement and proves that the retired thread never calls the
  replacement listener's `accept()` or request handler.
- The accepted-stream race proves that a stream accepted concurrently with
  retirement is closed and causes zero runtime calls.

These local gates validate the lifecycle contract and fail-closed request
boundary. They are not Linux acceptance evidence. A fresh hosted Linux run is
still required to close the original CI gate.
