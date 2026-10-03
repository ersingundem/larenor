# F62 owned initial-display and resize witness v2 — 2026-10-03

The native display contract now waits for the peer's actual Display Control
capabilities before sending the authenticated initial layout. The disposable
owned shadow fixture therefore distinguishes that initial request from the
later resize effect; an initial layout cannot satisfy the resize gate.

For the enabled first lifetime, the fixture accepts exactly an initial
1280 × 800 layout followed by a 1024 × 768 resize. For the disabled-clipboard
successor, it accepts exactly one initial 1024 × 768 layout. Both use actual
desktop/device scales 100/100. Wrong order, dimensions, scales, duplicate
layouts, missing initial evidence, unexpected clipboard activity or a third
lifetime fail closed. Only the enabled lifetime's second request can publish
the owned XRandR resize marker. The witness is fixed-width `LRNF62C2`, version
2; the old version cannot satisfy the new gate.

The source-locked patch is
`58e198fb1b12d8627132a53eac491d29154cc322210415f422d061b4a321c59d`,
applied to the pinned FreeRDP 3.31.1 release archive at commit
`63b948ca5cb94307fd5444ee6e73927a41ccdab4`. Root prepared that actual archive
in a private directory; patch application and every patched source digest
passed. The package/source provenance is independent of a fabricated witness.

Root's owned-fixture and packaged-acceptance portable suites passed **77
tests**, including missing/reordered/duplicated/legacy initial-layout evidence.
Pinned Ruff passed. The strict named Android acceptance remains one original
test, with zero skips; source classification is rebound to the revised host
test. No success receipt was generated from these local checks.

Root also verified the installed dual-ABI schema-2 product package. Its
focused native/Moonlight suites passed **90/90**, zero skips, failures or
errors, and `compileDebugAndroidTestKotlin` passed. The Linux fixture compile
and real owned-host render/clipboard/resize/keyboard run remain required. This checkpoint
does not prove OS scaling, physical display quality, relative-mouse support or
unimplemented audio, microphone, SAF or Gateway functionality. F62 remains
`reworking`.

Independent pinned-source review found no P1/P2 implementation issue in
callback ordering, locked counters, parser bounds, thread shutdown or exact
two-lifetime evidence. The prior fixture documentation was updated to the
current patch and schema; historical test records remain historical.
