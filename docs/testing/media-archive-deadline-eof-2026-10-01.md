# Media archive deadline/EOF classification — 2026-10-01

Android Build run `36813872693` at revision
`36269cf05091156ae960106eaec27810ff35fc78` exposed a timing boundary in
`test_timeout_never_repeats_a_write`: the owned loopback server accepted the
single DELETE and closed without a response after the request deadline, while
the response parser reported an invalid response. The adapter classified that
late parser error as `unmanic_protocol_changed` instead of the fixed
`unmanic_deadline_exceeded` result.

The transport now evaluates the same monotonic absolute deadline when a
bounded response-parser error reaches its error boundary. A parser timeout or
an error observed at/after the deadline is classified as deadline exceeded. An
empty response observed before the deadline remains a protocol change. Neither
path retries the write.

## Focused evidence

- RED: a deterministic real-loopback EOF delayed past the request deadline
  produced `unmanic_protocol_changed`; the server recorded exactly one write.
- GREEN: `server/tests/test_media_archive_http_transport.py` passed 10 tests.
- Root independently ran all 10 transport tests successfully; no cases skipped.
- The focused cases separately prove early EOF remains a protocol change,
  elapsed EOF becomes a deadline error, and the original stalled HTTP request
  is issued exactly once.
- The fixture owns its loopback server and synthetic request. No household or
  external provider was contacted.
