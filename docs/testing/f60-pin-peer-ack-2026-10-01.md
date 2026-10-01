# F60 owned PIN peer acknowledgement — 2026-10-01

## Observed boundary

Exact source `31f152c20cea3fde5b58b84b781be45564e90a54` in
[run 36816571516](https://github.com/ersingundem/larenor/actions/runs/36816571516)
failed before a JUnit report was retained. The source/package-bound public
failure receipt records `pinBridgeStage: readRejected`. This establishes that
the host bridge accepted the loopback connection and verified its peer, then
failed while reading the bounded canonical PIN frame. It does not distinguish
EOF, timeout, socket error or incomplete framing. The absent JUnit report is an
expected consequence of the runner terminating the owned Gradle process after
the bridge became terminal; it is not evidence of an application crash.

The Android test presenter previously treated `write` plus `flush` as completed
delivery and immediately left `Socket.use`, which closes both socket streams.
That is only a local write boundary. Android's official
[`Socket`](https://developer.android.com/reference/java/net/Socket) contract
states that closing the socket closes its input and output streams, while
[`OutputStream.flush`](https://developer.android.com/reference/java/io/OutputStream#flush())
only forces buffered output bytes to be written. Neither operation is an
application-level assertion that the host parsed the frame. ADB's primary
[`asocket`](https://android.googlesource.com/platform/packages/modules/adb/+/f4965b77c694689c08855076eaf983c8e88646f9/socket.h)
model also keeps a packet queue between peers; a successful local write is not
the same contract as host parser consumption.

This is a source-proven ambiguity, not proof that close discarded correctly
sent bytes or that the ADB relay caused the exact hosted failure.

## Narrow fixture repair

The owned host now sends one fixed, nonsecret `LRNPIN1\n` acknowledgement only
after exact schema, nonce, four-digit PIN, canonical order and newline parsing
succeeds. The Android presenter keeps the same one-use socket open and requires
that exact acknowledgement followed by EOF before reporting delivery. Missing,
wrong and trailing acknowledgements fail before the production pairing worker
starts. A host acknowledgement write failure has the fixed public stage
`ackRejected`; no exception text, endpoint, nonce or PIN is published.

The existing ten-second delivery bound is absolute across thread scheduling,
connect, write and acknowledgement read. The outer owner closes the exact
active socket at the deadline, so a blocked write or read cannot outlive the
fixture operation. Payload bytes and received acknowledgement bytes are wiped;
cancellation and child-process ownership rules are unchanged.

After acknowledgement, the bridge still performs the actual Sunshine pending
pairing lookup and approval. The ACK proves only canonical fixture-frame
consumption. It does not prove provider approval, cryptographic pairing,
catalog, stream output, input, disconnect or local retirement.

## Test evidence

The real localhost regression failed before the repair because the client read
EOF instead of the fixed acknowledgement. It now requires the parsed-peer ACK,
host close, actual owned pending-pairing approval and final
`pairedClientObserved`. Companion cases preserve incomplete and malformed frame
rejection with zero acknowledgement and zero approval. A forced ACK write
failure produces only `ackRejected` and performs no pairing approval. The
original Android test executes the same acknowledgement parser against valid,
missing, wrong and trailing frames before provider I/O.

Local gates:

- `PYTHONPATH=. python3 -m unittest
  tool.tests.f60_sunshine_android_stream_test
  tool.tests.f60_sunshine_android_stream_workflow_test`: **56 passed**.
- `python3 -m py_compile tool/f60_sunshine_android_stream.py
  tool/tests/f60_sunshine_android_stream_test.py`: passed.
- scoped `git diff --check`: passed.

Root additionally passed 56 runner/workflow tests after review. The actual required-product `:app:compileDebugAndroidTestKotlin` initially exposed a Kotlin nested-class helper visibility error; moving the shared parser/deadline helpers into the companion object fixed it. Root then passed the complete AndroidTest compilation with both packaged native engines required. A changed-source hosted stream run remains pending. F60 remains reworking; this fixture repair is not a stream acceptance
receipt and does not assign an exclusive cause to run 36816571516.
