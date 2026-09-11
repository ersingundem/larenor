# Remote access integration evidence — 2026-09-11

## Exact integration inputs

- Base: `origin/main@a1a62ca66d97be2e46064b309f68d67f30051136`
- RDP native contract: `codex/rdp-native-adapter@3186039bd3f0aab8c64d046e95e76dbf785d1ba4`
- Consolidated VNC foundation: `codex/vnc-consolidated-main@181aff26f97ef98d32e177126c3f463af29e50bd`
- Integration branch: `codex/integration-remote-cluster`

Both source heads are retained as second parents of explicit merge commits. The integration merges produced no content conflict. The VNC source head had already resolved its `main` rebase by preserving every retained Music Assistant EN/TR key and adding all 25 VNC keys; JSON parsing, generated localization compilation, focused widget tests and formatting verify that resolution.

## Automated coverage

| Surface | Focused evidence | Boundary covered |
| --- | ---: | --- |
| Android RDP native contract | 6 Kotlin tests | capability negotiation, certificate trust, input and lifecycle fail-closed states |
| Flutter RDP client | 21 tests | explicit connect, PIN/account/route retirement, saved secret reuse, tablet/DeX input and no automatic reconnect |
| Android VNC adapters | 43 Kotlin tests | contract, bridge, parser, VeNCrypt/SPKI, bounded TCP/TLS seam, cancellation and single ACK |
| Flutter VNC client | 32 tests | profiles, encrypted pin ownership, lifecycle discard, bounded framebuffer, input backpressure and 2x tablet UI |

The combined gate also runs scoped Flutter analysis, Dart formatting, `git diff --check`, commit progress validation and queue validation. No queue or feature completion is claimed by this integration: progress remains 14/125 (11.2%) and 0/63 (0.0%).

## Security and acceptance boundary

Credentials remain in Android secure storage and neither contract records passwords, tokens, clipboard contents or raw peer errors. Route, account, PIN and background retirement invalidate late results. Certificate/SPKI changes, malformed or oversized frames and capability downgrade fail closed without automatic retry or replay.

This integration does not close physical acceptance. RDP still needs a packaged FreeRDP backend and real Windows/RD Gateway validation. VNC keeps `productionAvailable=false` until the packaged engine, real Android TLS/RFB transport and representative server interoperability are proven. Huawei tablet, Samsung DeX, external display, keyboard, pointer and clipboard behavior still require physical-device validation.
