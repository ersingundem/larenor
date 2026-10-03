# F62 SAF unknown recovery follow-up 5 — 2026-10-03

This private follow-up closes one result-lifecycle gap found during independent review of
follow-up 4. If the operation deadline fired while the durable `UNKNOWN` journal write failed,
the manager correctly retained the active generation and process owner. A later worker or native
completion could nevertheless enter the same failure path and invoke the public callback again.

Each reserved mirror operation now owns a separate one-shot result gate. Deadline, worker,
native-close, and error paths may all try to publish, but only the first value reaches the
MethodChannel owner. The durability rule is unchanged: a failed `UNKNOWN` write does not clear the
active generation, does not admit a successor, does not release the process owner, and does not
turn a late completion into success.

The focused regression blocks an exact provider create, rejects the timeout's `UNKNOWN` journal
write, observes one public `Unknown`, proves a successor remains `busy`, then releases the old
worker and proves its late completion cannot publish a second result. Manager quiescence remains
false because the durable owner fence could not be written. The test performs no real provider,
device, network, or household effect.

This is private source/test evidence only. It does not accept F62, enable `files` or `rdGateway`,
or replace the owned hosted Gateway/SAF runtime gate.

## Focused proof

The new test against the frozen follow-up 4 manager failed as intended: **1 test / 1 failure /
0 errors / 0 skips**. With the one-shot gate restored, the three focused SAF classes passed
**29 tests / 0 failures / 0 errors / 0 skips**. Both runs used the already cached Gradle 9.7.1
distribution with Java 17 and offline dependency resolution. The media plugin prints fixed
configuration-time URL messages even in offline mode; no Gradle distribution was downloaded.
