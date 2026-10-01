# F60 one-shot PIN newline framing

The private Android-to-host PIN wire is one canonical JSON object terminated by
one newline. The host previously read one more byte after receiving that full
line to require transport EOF. An adb reverse peer may keep its socket open
after flushing the one-shot message, so that extra read could hold the pairing
approval path until the socket timeout even though the complete authenticated
message was already available.

The receiver now returns as soon as it reads the complete canonical newline
frame. It still fails closed for a newline with trailing bytes in the same
read, an over-limit frame, EOF before newline, duplicate JSON keys, a wrong
64-hex nonce, a non-four-digit PIN, or noncanonical key order/encoding. The
listener remains one-use and closes after that single accepted connection, so
this change does not add replay or a second PIN delivery path. The public
diagnostic schema and its fixed bridge stages are unchanged.

## Focused evidence

Before the implementation change, the new real localhost regression
`test_pin_bridge_processes_canonical_line_before_client_eof` failed because
`OneShotPinBridge._receive` blocked in the extra `recv(1)` and raised
`socket.timeout`; no PIN approval occurred. After the change, the client keeps
the connection open while `bridge.wait()` reaches `pairedClientObserved` and
the owned host records exactly one approval.

The companion regression
`test_pin_bridge_receive_rejects_same_read_trailing_and_incomplete_frames`
passes same-read trailing bytes, newline-less EOF, and an over-limit frame
through the actual socket receiver and requires rejection. Existing parser and
bridge tests retain canonical encoding, nonce, PIN, duplicate-key, bounded
size, fixed-stage, and one-use checks.

Local results:

```text
python3 -m unittest -v \
  tool.tests.f60_sunshine_android_stream_test
# 35 tests, 0 failures, 0 errors, 0 skipped

python3 -m unittest -v \
  tool.tests.f60_sunshine_android_discovery_test \
  tool.tests.f60_sunshine_android_stream_test \
  tool.tests.f60_sunshine_android_stream_workflow_test
# 61 tests, 0 failures, 0 errors, 0 skipped

python3 -m unittest -v \
  tool.tests.f60_owned_gamepad_test \
  tool.tests.f60_sunshine_owned_host_test \
  tool.tests.f60_sunshine_android_stream_test \
  tool.tests.f60_sunshine_android_stream_workflow_test
# 93 tests, 0 failures, 0 errors, 0 skipped
```

The earlier hosted embed-v2 failure remains diagnostically inconclusive: its
fixed public stage was `listening`, which did not distinguish an absent adb
reverse connection from a connection stalled before canonical parsing. This
source-proven EOF dependency can explain that timing but is not asserted as the
exclusive cause. A changed-source hosted run is still required.
