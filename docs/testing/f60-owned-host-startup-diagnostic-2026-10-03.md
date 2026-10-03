# F60 owned-host startup failure diagnostic

The exact `15ba` hosted run failed before Android instrumentation: the owned Sunshine process exited while the runner was waiting for its pinned API. The old path removed the private fixture workspace during `OwnedSunshineHost.start` cleanup and raised before the stream runner could write an artifact. The historical run therefore proves only `host process exited before readiness`; it does not prove which Sunshine subsystem caused the exit.

This private repair keeps the original failure primary. `OwnedSunshineHost.start` records the current fixed startup phase before every effect and polls only the processes it spawned. On a `HostFailure`, before process/workspace cleanup, it:

1. classifies only the fixed phase, owned process, poll state, and exit class;
2. scans bounded owned Sunshine logs for four fixed phrases and maps them to `encoderUnavailable`, `captureUnavailable`, `displayUnavailable`, or `portUnavailable`; every other line maps to `unclassified`;
3. copies existing owned regular logs with no symlink following into a fresh `RUNNER_TEMP/f60-host-startup-private-*` directory with directory mode 0700 and file mode 0600; and
4. removes the original private workspace and raises `HostStartupFailure` with a fixed message and the closed observation only.

The fixed phrases correspond to documented Sunshine startup failures such as “Couldn't find any working encoder” and “Unable to initialize capture method”; the receipt does not repeat those phrases or any log text. Raw logs, endpoints, credentials, certificates, process IDs, paths, and exception messages remain private and are never placed in the public artifact.

The stream runner catches only `HostStartupFailure`. It writes the usual failure artifact filename with this separate exact schema:

```json
{
  "schemaVersion": 1,
  "gate": "owned_sunshine_android_stream",
  "sourceRevision": "<40 lowercase hex>",
  "emulatorVersion": "<bounded version>",
  "moonlightPackage": "<existing exact package identity object>",
  "result": "failed",
  "phase": "hostStartup",
  "counts": null,
  "startup": {
    "stage": "<fixed enum>",
    "process": "none|audio|display|sunshine|multiple",
    "poll": "notStarted|running|exited",
    "exit": "unavailable|zero|nonzero|signal",
    "knownCode": "unclassified|encoderUnavailable|captureUnavailable|displayUnavailable|portUnavailable",
    "privateLogs": "preserved|unavailable"
  },
  "streamAccepted": false,
  "featureAccepted": false
}
```

`counts` is deliberately null because no instrumented test started. The receipt has no `namedTest`, frames, acceptance stage, PIN phase, or stream-output claim. It cannot satisfy the existing one-test/zero-skip validator and cannot enable the product. Receipt creation remains exclusive 0600, source/package bound, bounded to 8 KiB, and secondary: a storage or validation error cannot replace the startup failure or change its nonzero outcome.

Focused regressions cover exact host exit and exit class, a known fixed log classification without raw text publication, log preservation across workspace cleanup, missing/symlink/oversize log rejection, arbitrary-string injection, impossible enum combinations, an existing receipt/symlink, and receipt-write failure preserving the original startup error.

## Local evidence

```sh
PYTHONPATH=<private-overlay>:/Users/ersingundem/oikos \
  /Users/ersingundem/oikos/server/.venv/bin/pytest -q \
  tool/tests/f60_sunshine_owned_host_test.py \
  tool/tests/f60_sunshine_android_stream_test.py
```

The focused suite passed 102 tests and 75 subtests. This is diagnostic evidence only. No same-source CI rerun, Android build, provider acceptance, stream acceptance, or product capability admission was performed.
