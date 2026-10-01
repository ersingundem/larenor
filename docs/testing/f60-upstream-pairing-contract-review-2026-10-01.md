# F60 upstream pairing contract review — 2026-10-01

## Scope and immutable sources

This review compares the owned F60 Sunshine host helper with the exact provider
and client sources used by the acceptance harness. It is a source-contract
review; it is not a successful runtime pairing or streaming receipt.

- Sunshine release: `v2026.914.233613`
- Moonlight Android upstream commit:
  `b48494cb96bff23d8886c4775cc4f39a1075495d`
- Moonlight engine revision used by Larenor:
  `moonlight-android-12.2-larenor-embed-v3`
- Larenor host implementation:
  `tool/f60_sunshine_owned_host.py:496-650`
- Larenor pairing orchestration:
  `tool/f60_sunshine_android_stream.py:68,382-407`

Pinned primary sources:

1. [Sunshine `confighttp.cpp` at v2026.914.233613](https://github.com/LizardByte/Sunshine/blob/v2026.914.233613/src/confighttp.cpp)
2. [Sunshine `nvhttp.cpp` at v2026.914.233613](https://github.com/LizardByte/Sunshine/blob/v2026.914.233613/src/nvhttp.cpp)
3. [Moonlight `NvHTTP.java` at b48494c](https://github.com/moonlight-stream/moonlight-android/blob/b48494cb96bff23d8886c4775cc4f39a1075495d/app/src/main/java/com/limelight/nvstream/http/NvHTTP.java)
4. [Moonlight `PairingManager.java` at b48494c](https://github.com/moonlight-stream/moonlight-android/blob/b48494cb96bff23d8886c4775cc4f39a1075495d/app/src/main/java/com/limelight/nvstream/http/PairingManager.java)

## Contract mapping

Moonlight's `NvHTTP.executePairingCommand()` and pairing challenge append the
literal `devicename=roth`. Sunshine's `start_pairing_session()` copies that
query value into the pending pairing record. Therefore the harness constant
`PAIRING_CLIENT_NAME = "roth"` is the exact pending name supplied by the pinned
client rather than a locally invented identity.

`PairingManager.generatePinString()` creates exactly four decimal digits. Its
initial `phrase=getservercert` request remains pending while the user or owned
harness supplies that PIN. Sunshine validates a 32-character hexadecimal
pairing ID, a four-digit PIN, and a 1–128-byte client name before invoking
`nvhttp::pin()`.

The HTTP schemas consumed by `SunshineApi` match the pinned Sunshine handlers:

- `GET /api/pin` returns
  `{"pairings":[{"id","name","address"}]}`;
- `POST /api/pin` accepts `{"pairing_id","pin","name"}` and returns
  `{"status":true}` only after the retained `getservercert` request is released
  and the Moonlight cryptographic pairing sequence completes;
- `GET /api/clients/list` returns
  `{"named_certs":[{"name","uuid","enabled"}],"status":true}`.

Sunshine first exposes Moonlight's `devicename` in the pending record, then
stores the explicit POST `name` on the paired client. Using `roth` for both
`pending_pairing()` and the later enabled-client UUID lookup is consequently
consistent with the pinned implementation. The local sequence—observe the
pending ID, submit the PIN, require confirmed status, then read the single
enabled client UUID—also matches Sunshine's state transition.

The host helper sends authenticated non-browser requests without `Origin` or
`Referer`. The pinned `validate_csrf_token()` explicitly allows that case;
therefore omission of `X-CSRF-Token` is compatible with this exact script
client. Browser-originated requests remain subject to Sunshine's origin/token
checks.

No endpoint, request field, response field, client-name, PIN-format, or CSRF
incompatibility was found in this comparison. The helper's 10-second HTTP
timeout and Sunshine's default 10-second `ping_timeout` are equal bounds, but
that equality alone is not evidence of a defect or the cause of a historical
failure.

## Runtime evidence boundary

This review establishes only the static upstream contract. A hosted result
whose PIN bridge remained at `listening` does not identify whether the Android
client failed before connecting, failed transport framing, or failed later in
the provider handshake. Actual production acceptance still requires the named
owned-Sunshine run to observe the pending pairing, confirmed approval, paired
UUID, catalog, stream, output, input, stop, and local-retirement evidence under
its existing strict receipt rules.
