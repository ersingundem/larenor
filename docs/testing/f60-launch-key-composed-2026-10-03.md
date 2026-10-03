# F60 RI-key v5 composed gate — 2026-10-03

## Behavior and source boundary

The embedded provider launch and the packaged Game connection now share one
process-private remote-input AES key and key ID. A matching running app uses
the pinned provider `resume` operation with a fresh key; it is preserved rather
than quit solely for key acquisition. A missing app uses `launch`, and a different
running app retains the existing explicit quit-and-launch path. A provider reply
and exact current-game readback are required before the handoff is published.

The v5 package retains Moonlight's public seven-argument constructor and adds a
protected Game connection factory plus a nine-argument explicit-key constructor.
No RI key enters an Intent, MethodChannel, DTO, journal, public receipt, or log.
The consumed array is one-use and wiped after constructor success or failure.

## Actual product mount

Root installed and independently verified the real dual-ABI v5 Moonlight AAR
with the existing dual-ABI microphone-v4 FreeRDP package. The private product
receipt SHA-256 is
`d08a3a570f8d7e4e165ffc8b4a1a34dc969a8d9472632edc2076461201e3a81f`.
The v5 AAR SHA-256 is
`ec3e8fc3023848046e38e2ceefcb482a15e9c91895e5a247de47e6a0c6d759a5`;
its package receipt SHA-256 is
`2000bb39fddac16f9027fae62732767d2d277ff786cad47f6c552737a1d348db`.
The existing ignored shared product mount was preserved privately before
replacement. No package artifact is committed to the repository.

Root's 18 Moonlight/product package tests and 70 owned-stream runner/workflow
regressions passed (88 portable tests total). With the real mounted v5 AAR,
root's composed native gate passed **146/146** tests with zero skips, errors,
or failures: 47 Moonlight runtime + 8 launch-key ownership + 78 existing RDP +
13 preparing-SAF regressions. Actual AndroidTest Kotlin compilation passed;
Gradle completed 315 tasks. The SAF subset is a separately prepared grant slice,
not proof of file redirection or current full F62 completion.

The passing frozen working tree was based on `4e92c57e857e9e8429a0903478f0adcb0f1b91de`.
Its 1,227-source manifest was unchanged at gate completion. Manifest SHA-256:
`2e3fcd1601b5a4a5fa2e216cefd4339a7fcf3cbb56d4934eaf2a12143aca27ca`. Private Gradle log SHA-256:
`2f43cb78bcaa37b74da2a105e35304fb9ddf30e5ac4739c3d6ee5a0978cca626`. JUnit XML and exact launcher command were retained
privately. Two production Kotlin typing issues and then three test typing/fixture
issues were fixed narrowly before this passing gate; failing attempts were not
called acceptance.

## Acceptance boundary

This slice is a real source and package compatibility repair. It is not evidence
of a hosted Sunshine stream. The changed exact source still needs the existing
strict owned-host launch/RTSP/decoded-frame/nonzero-PCM/input/two-lifetime/close
acceptance. Historical failed strict runs remain failed. F60 and FINAL.FUNCTION
remain open, and the accepted queue/feature counts do not increase.
