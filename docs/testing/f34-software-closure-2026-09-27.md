# F34 QR inventory software closure — 2026-09-27

F34 is accepted at exact source
`9295ee46aef97816e166c657caa75019c4e8ee9f`. Its stable patch-id
`18e2e1896da8f0b04cdd4670170c61d7db3fe8b9` matches the merged main squash
`a1fc2d7fe26830a9dbd758d1e69ac6647951a564`, so the accepted source is present
in the current base even though the commit identity changed during squash.

## Acceptance evidence

- The inventory Client, tablet surface, printable label share path and real
  loopback TCP/HTTP isolated-Core package passed **29/29** tests on the exact
  accepted source. The Server contracts cover stable inventory identity,
  encrypted persistence, room/device/document resolution, authorization,
  malformed and foreign QR input, bounded pagination and authenticated cursor
  handling.
- Independent final review found no remaining P1/P2 issue in Server authority,
  late-response retirement, scanner ownership, share lifecycle/focus authority
  or secret projection. The earlier fail-closed ownership defect was fixed by
  `cbf3b2fc1b89599e212d31a273e46497be9fec12` before the accepted source.
- [Android Build 35873820006](https://github.com/ersingundem/larenor/actions/runs/35873820006)
  passed on the exact accepted source.
- [Security 35873818998](https://github.com/ersingundem/larenor/actions/runs/35873818998)
  passed on the exact accepted source.

B0, B3 and B5 are complete. Physical camera scanning, printing/share targets
and tablet behavior remain in the corresponding `MANUAL.*` matrix and do not
claim software acceptance evidence.
