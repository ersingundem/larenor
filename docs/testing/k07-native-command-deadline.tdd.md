# K07 native command deadline and retirement

Date: 23 September 2026

The managed-tablet runtime already serialized broker connections and retired
native leases on authority or lifecycle changes. Android `start`, `snapshot`
and `command` channel futures themselves had no total deadline, however, and a
retired command could wait for the native reply before producing its MQTT
acknowledgement.

## Three-job acceptance boundary

1. Every native start, telemetry snapshot and command call has one configured
   total deadline. A timeout cannot be extended by a late platform callback;
   start cleanup and native stop are bounded by the same policy.
2. Each pending generation owns a local retirement signal. Background, scope
   replacement or explicit retirement completes a pending command immediately
   as `denied`, independent of the unresolved native future.
3. A late success/error from the retired generation is observed and discarded.
   It cannot publish an acknowledgement, reopen the lease, cancel the new
   session or change a replacement command result.

The source remains disabled by default. The MethodChannel still carries only
the 32-hex session ID, exact command kind and bounded telemetry fields; pairing
tokens, URLs and arbitrary arguments are absent.

## RED to GREEN evidence

The RED run failed during compilation because the bounded native-call policy
did not exist. GREEN passes three focused deadline/retirement regressions:

```text
flutter test \
  test/features/kiosk_remote/native_managed_tablet_source_deadline_test.dart
3 passed
```

The final batch ran the existing native source, runtime owner and MQTT runtime
suites together: **46/46 passed**. Focused `flutter analyze` reported no issues;
the security policy, execution-queue validation and `git diff --check` gates
also passed.

The independent ownership audit then recorded failing commit `84f52a95`: a
retirement stop could run before a pending native start returned `active`, and
the late acknowledgement no longer triggered a second exact cleanup. Commit
`a7415639` restores that bounded post-ack stop without adding another stop to
current-generation malformed or timeout paths.

## Final acceptance

K07 software acceptance is `done`. Live TLS fixture, trusted enrollment and
bounded native/profile commands are automated; queue and selected-feature
counters are **29/125** and **0/63**. Real Mosquitto deployment, Huawei
background behavior, Samsung DeX and physical keyboard/TalkBack checks remain
MANUAL.
