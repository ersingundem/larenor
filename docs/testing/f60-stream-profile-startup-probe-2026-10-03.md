# F60 stream-profile startup probe

The `f60-startup-probe` Server workflow scope starts the real pinned Sunshine host with the same stream profile and exact Ubuntu prerequisites used by the strict packaged-Android stream gate. It performs no Android, Flutter, Moonlight package, emulator, KVM, pairing, streaming, audio, input, or retirement acceptance work.

The probe exists to isolate host startup before the expensive Android gate. It calls `OwnedSunshineHost.start(stream_profile=True)`, checks the existing source-owned readiness projection, closes the real host, and publishes a bounded source-bound receipt. It does not extend the 30-second host readiness deadline.

Both successful readiness and failed startup receipts keep these facts explicit:

- `counts` is `null`; no Android test or named test ran.
- `streamAccepted` and `featureAccepted` are `false`.
- the exact pinned Sunshine tag and package digest are included.
- `sourceRevision` binds the receipt to the checked-out commit.

On startup failure, the receipt contains only the closed stage, owned process class, poll state, exit class, fixed known code, and whether private logs were preserved. Raw logs remain in the runner's private `0700` directory with `0600` files and are not uploaded by this workflow. Arbitrary process output, endpoints, credentials, hostnames, and provider messages cannot enter the public receipt.

The reusable workflow is reachable only directly on an allowed branch or through the exact registered `server-test.yml` contract. It remains outside the required Server aggregate and leaves the strict `f60-stream` workflow unchanged.

Focused local validation covers the real-call boundary (`stream_profile=True`), success and failure receipt shapes, hostile or impossible startup observations, exclusive receipt creation, caller/source guards, scope isolation, and the absence of Android or emulator setup from the probe workflow. A hosted run is still required to prove current GitHub-hosted Sunshine startup; local tests do not claim that effect.
# Root integration check

Root verified both private patch and source manifests before applying the diagnostic and probe together. A readiness timeout with a still-running owned process initially lost its closed receipt; two new regression tests reproduced the failure. The validators now preserve this bounded observation while rejecting inconsistent exit states. The combined host, stream, startup-probe, and dispatcher suite passes 114 tests. Scoped Ruff and actionlint are required before dispatch. This startup-only gate does not validate Android streaming or accept F60.
