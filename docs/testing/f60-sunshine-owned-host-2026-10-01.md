# F60 owned Sunshine host harness — 2026-10-01

## Scope

`tool/f60_sunshine_owned_host.py` implements only the host half of the future
Sunshine-to-packaged-Android acceptance gate. It is not a provider fake and it
does not accept a caller-selected host, release, route, process ID, capture
backend, encoder, codec, or successful receipt.

The executable refuses anything except an x86_64 GitHub-hosted Ubuntu 24.04
runner. Its only CLI mode is `--readiness-only`; the emitted public object says
`state: host_ready` and `streamAccepted: false`. A real hosted run has not been
performed for this slice, so this document makes no Sunshine interoperability
or streaming-success claim.

`.github/workflows/f60-sunshine-owned-host.yml` is a manual, same-repository
host smoke on `ubuntu-24.04`. It pins the reviewed checkout action, resolves and
installs exact Ubuntu candidate versions for Avahi, OpenSSL, PulseAudio,
`pactl`, Xvfb and `xdpyinfo`, and records those versions in the public receipt.
The helper still independently downloads, hashes, installs and reads back the
pinned Sunshine package.

## Pinned provider identity

The harness uses the official Sunshine release `v2026.914.233613` and only this
Ubuntu 24.04 amd64 asset:

```text
sunshine_2026.914.233613-1+ubuntu24.04_amd64.deb
size:   11001782 bytes
sha256: c38e9c705f650f8705f61702717e99bec34044c5028fcb8f23a08fe041292c21
```

Primary sources:

- release and asset: <https://github.com/LizardByte/Sunshine/releases/tag/v2026.914.233613>
- release metadata: <https://api.github.com/repos/LizardByte/Sunshine/releases/tags/v2026.914.233613>
- Ubuntu installation contract: <https://github.com/LizardByte/Sunshine/blob/v2026.914.233613/docs/getting_started.md>
- X11/software encoder configuration: <https://github.com/LizardByte/Sunshine/blob/v2026.914.233613/docs/configuration.md>
- upstream Xvfb build test: <https://github.com/LizardByte/Sunshine/blob/v2026.914.233613/docker/debian.dockerfile#L87-L95>
- Linux virtual-audio implementation: <https://github.com/LizardByte/Sunshine/blob/v2026.914.233613/src/platform/linux/audio.cpp>
- PIN/client API: <https://github.com/LizardByte/Sunshine/blob/v2026.914.233613/src/confighttp.cpp>

The download is HTTPS-only, bounded to 16 MiB, accepts redirects only to
GitHub's release hosts, and must match both the exact byte count and SHA-256.
Installation uses one fixed local `.deb` argument, then requires the exact
`dpkg-query` version `2026.914.233613-1+ubuntu24.04`.

## Private runtime and lifecycle

The harness reads the canonical regular `/usr/lib/os-release` file with
nofollow semantics. This avoids following Ubuntu's permitted
`/etc/os-release` symlink while retaining exact Ubuntu 24.04 validation.

The harness creates one runner-owned workspace beneath `RUNNER_TEMP`. The
workspace and each subdirectory are mode `0700`; configuration, logs, state,
certificate, key, release and API material are mode `0600`. The directory's
device/inode identity is retained and checked before recursive cleanup.

It generates a one-day RSA-2048 identity with SANs only for `127.0.0.1` and
`localhost`. The Web API uses a CA context built from that exact certificate,
with hostname verification and `CERT_REQUIRED`; there is no `-k`, permissive
trust manager, browser origin, or referer. Web credentials are random and held
in memory. Sunshine's official `--creds` path receives them without stdout or
stderr capture, and neither the plaintext password nor a PIN is written to a
public receipt.

The three persistent children are created directly without a shell:

1. PulseAudio with daemonization disabled and a private `XDG_RUNTIME_DIR`;
2. Xvfb `:99`, `1280x720x24`, TCP disabled; and
3. the exact `/usr/bin/sunshine` process with the private config.

Process existence is not used as readiness. Before Sunshine starts, bounded
fixed-argument probes must successfully query the private PulseAudio socket
with `pactl info` and the exact Xvfb display with `xdpyinfo`. Sunshine readiness
then requires its pinned local API plus an mDNS observation while all three
owned children remain alive.

Every process is retained as the exact `Popen` object created by the harness.
Cleanup walks those owned objects in reverse order, terminates, waits for five
seconds, and kills only a child that did not stop. No PID file or caller PID is
accepted. The CLI maps SIGTERM/SIGINT into the same context cleanup path, so a
superseded workflow does not deliberately leave provider children behind. Logs
remain inside the private workspace and are removed after the owned processes
stop.

The configuration fixes `capture=x11`, `encoder=software`,
`sw_preset=ultrafast`, `hevc_mode=1`, `av1_mode=1` and a 2,000 kbps ceiling.
It disables UPnP and host keyboard/mouse/controller injection. No `/dev/dri`,
KMS, VA-API, NVENC, CUDA or privileged capture option is configured. Sunshine's
tagged Linux audio implementation creates `module-null-sink` sinks when a
stream begins; starting PulseAudio alone is not reported as decoded audio.

## Exact private API surface

The pinned local client allows only:

```text
GET    /api/pin
POST   /api/pin
DELETE /api/pin
GET    /api/clients/list
POST   /api/clients/unpair
```

Every request is Basic-authenticated over the pinned TLS connection. JSON is
canonical and bounded. Responses reject duplicate keys, extra keys, invalid
types, invalid IP addresses, duplicate IDs and more than 64 pending pairings or
256 clients.

The request validators reproduce the official source limits before any I/O:

- pairing ID: exactly 32 hexadecimal characters;
- PIN: exactly four decimal digits;
- client name: 1–128 UTF-8 bytes; and
- unpair UUID: one canonical 36-character UUID representation.

`pending_pairing()` returns only the exact owned pairing ID; the observed
source IP is validated and discarded. `owned_client_uuid()` requires one exact
enabled owned name. There is no `unpair-all` helper. The separate Android
orchestrator must start the real cryptographic Moonlight pairing first, capture
the production PIN privately, approve only that pending pairing, and use the
returned exact UUID for cleanup. Because Sunshine may exit after removing its
last client, the full future gate must restart the same private instance before
claiming an absence readback.

The mDNS helper reads the single up default interface from `/proc/net/route`
and invokes Avahi for IPv4 on only that interface. It accepts the fixed owned
service name `Larenor-F60-Owned`, `_nvstream._tcp` and port 47989. Multiple
IPv4/IPv6 or interface observations of that exact service identity are deduped;
a second hostname or port is rejected. Addresses are validated but never
returned or receipted. Pinned
Moonlight v12.2 uses Android `NsdManager` on API 34+, specifically citing
emulator mDNS proxying:
<https://github.com/moonlight-stream/moonlight-android/blob/b48494cb96bff23d8886c4775cc4f39a1075495d/app/src/main/java/com/limelight/discovery/DiscoveryService.java#L52-L65>.
The actual packaged APK must discover this service through its production path;
an injected candidate cannot satisfy the gate.

## Focused software evidence

```text
python3 -m unittest tool.tests.f60_sunshine_owned_host_test
19 tests; zero failures/errors/skips
```

The tests cover the pinned release constants, runner/OS refusal, private
permissions and cleanup, bounded redirects and digest mismatch, fixed package
installation/readback, exact API methods and JSON bodies, malformed and
oversized responses, pre-I/O input rejection, TLS pin construction, secret-free
representation, exact mDNS parsing, direct process plans, reverse child cleanup
and the explicit non-acceptance readiness receipt.

## Registered same-commit dispatcher

Direct dispatch after commit `830de51a` returned GitHub404 because the new
workflow was not on the default branch; no hosted run was created. The existing
registered `server-test.yml` now accepts the separate manual `f60-host` scope.
It calls this local reusable workflow from the same commit with the fixed
`f60-owned-host-v1` contract. Exact caller workflow/ref, repository, source SHA,
allowed branch and GitHub-hosted execution are independently checked.

This scope skips the unrelated Server shards, F08 and host-worker jobs. It is
not a Server required-aggregate success. Wrong caller/contract/ref/SHA are
rejected by extracted real shell guard tests. Root passed19 host/dispatcher plus
47 workflow/policy tests and actionlint for both workflows.

## Evidence still required

The new workflow has not yet been dispatched at this source revision. This
slice therefore
does not yet prove Xvfb capture, CPU H.264 encoder initialization, emulator mDNS
visibility, cryptographic pairing, NvHTTP catalog/launch, RTP transport,
MediaCodec decoded frames, Android audio, causal stop, restart reconciliation,
or owned-client absence after unpair.

The later combined gate must run the packaged APK against this owned host and
record only a sanitized public receipt. A passing owned fixture would cover
Ubuntu Xvfb plus software H.264 on that emulator. Physical displays, household
Sunshine, GPU/HDR/HEVC/AV1 performance, speakers, controllers and real network
latency remain separate manual evidence.
