# F62 owned effect-control separation — 2026-10-03

## Scope

The owned FreeRDP acceptance used its lifecycle diagnostic marker to decide
when the Linux fixture should arm remote audio and microphone input. The
`06ef24fae316453c58f404c2c2046483ff24ce0b` run produced a canonical failure
receipt with an available but invalid marker. That receipt does not identify
the failed assertion, but it proved that a diagnostic read failure could also
withhold a required fixture effect.

The control path is now separate from diagnostics. The Android test writes two
distinct one-shot records, in order:

1. `audio`
2. `microphone`

Each record is exactly 208 ASCII bytes: an eight-byte schema magic, an
eight-byte phase code, the 64-hex invocation nonce, the 64-hex current Android
test source digest, and the 64-hex digest of the fixed test class and method.
The runner validates the entire record, consumes it, and only then writes the
corresponding nonce-bound host arm pipe. A wrong nonce is not discovered under
the invocation's filename; a wrong source, test, phase, length, ordering, or
replay fails closed as `host_channel_witness_invalid` without arming an effect.

Lifecycle storage remains diagnostic-only. An absent, invalid, or unavailable
diagnostic marker can no longer starve either effect or upgrade a result. The
original single Android test, zero-skip rule, audio completion witness,
microphone submission witness, two authenticated lifetimes, frame checks,
input effect, DISP resize, clipboard effect, credential clearing, and close
checks remain required.

## Focused evidence

TDD RED was established before the runner implementation: the three new tests
failed because the fixed record encoder, phase machine, and control poller did
not exist.

After implementation:

- `python3 -m unittest tool.tests.f62_packaged_acceptance_test` — 67 passed.
- `python3 -m py_compile tool/f62_packaged_acceptance.py tool/tests/f62_packaged_acceptance_test.py` — passed.
- `git diff --check --` for the three source/test files — passed.
- The Android acceptance source digest bound by the runner is
  `6fa2825ecb455cf30dc1d4412bc75cc30a1417df0a3029862dbc66e193daeaa0`.

The focused fixture regression drives the baseline with invalid lifecycle
evidence and valid audio/microphone control records, and still observes each
arm exactly once. Separate regressions reject malformed records, wrong source,
wrong nonce, wrong test binding, out-of-order phases, and replay.

## Boundaries

Root integration passed **78/78** packaged-runner/workflow tests and scoped
Ruff 0.14.1. The actual required native product also passed
`:app:compileDebugAndroidTestKotlin`; its four-source manifest remained
unchanged. Private manifest SHA-256:
`35920c9b194c6bbc5cd870c604b8b9e6cd3c48d9441efeb4894bb0db4176d499`;
Gradle log SHA-256:
`750ffbfad6bbd060fe71a32a63255dcef589c22eb2548fca84903d4c38d0c5d1`.

These gates establish the control-channel contract and compiled runner/test
composition. They do not establish successful remote audio or microphone
effect on an owned provider; changed-source hosted acceptance remains open.
