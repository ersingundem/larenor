# F60 stream-dispatch stage diagnostics — 1 October 2026

Changed-source run `36822674910` at revision
`c9fee6d7ed83807af7917c89b26a7315966ce6cb` reached production discovery,
pairing, catalog registration, policy selection, session binding, and remote
launch. Its exact named Android test then failed at the first stream command
with one test, one failure, zero errors, and zero skips. The existing bounded
receipt recorded `unknown/unknown/unknown` and an exact lease classification of
`absentOrUnreadable`. That evidence could not distinguish synchronous failure
before lease issuance from a later Activity-launch or callback failure.

The runtime now keeps one process-private diagnostic trace for the exact
authority fingerprint, request, session and revision, command, and journal
fingerprint. The trace records only these fixed stages:

- `beforeIssue` before current capability, policy, and preference validation;
- `postIssued` after an exact foreground lease is issued and bound;
- `launchReturned` after the private Activity launch returns;
- `callback` when the exact lease observer wins completion;
- `timeout` when the existing 30-second fail-closed timeout wins completion.

An obsolete callback or timer cannot update a successor command's trace.
Reading the trace requires the current authority and bound session plus an
exact matching command journal record; stale or foreign reads fail closed.
The public command receipt, timeout, strict rendered-frame and full-PCM
requirements, input effects, second lifetime, disconnect, and local-retirement
requirements are unchanged.

When the original strict assertion fails, the Android test may append a second
fixed marker. It includes the stage, an allowlisted exact Throwable class, and
the closed repository-owned `MoonlightRuntimeFailure` code when applicable.
All other Throwable subclasses become `unclassified`. Messages, stack text,
provider data, endpoints, tokens, certificates, pixels, PCM, and native
payloads never enter the marker. The original `F60_STREAM_COMMAND_V1` marker
remains byte-for-byte unchanged.

The Python publisher accepts the added marker only alongside the original
valid marker, exact named one-test failure with zero skips, owned source frame,
and exact Android-test source hash. Duplicate markers, extra fields, unknown
classes or codes, and mismatched class/code pairs are ignored. Its output is a
separate `streamDispatch` object in the bounded failure diagnostic; it cannot
turn the strict failure into acceptance.

Source and parser regressions cover every fixed stage, closed runtime and
Throwable classification, unclassified private exceptions, terminal-stage
immutability, successor isolation, duplicate/private/mismatched markers, and
the existing hostile report cases. The focused Python command was:

```text
python3 -m unittest \
  tool.tests.f60_sunshine_android_stream_test \
  tool.tests.f60_sunshine_android_stream_workflow_test
```

It passed 60 tests. The focused `MoonlightEmbeddedRuntimeTest` JVM gate passed
42 tests with zero failures, errors, or skips. Production and AndroidTest
Kotlin compilation then completed successfully with 277 actionable Gradle
tasks. These diagnostics are not stream acceptance and do not establish a
provider or engine cause.
