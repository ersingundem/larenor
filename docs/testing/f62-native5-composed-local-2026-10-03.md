# F62 native5 composition and admission review — 2026-10-03

Prepared privately from completion HEAD
`847b1f576ebab39ab92c9cd008c036a817672188`. These are local implementation
results, not hosted Gateway, RDPDR, audio, microphone, or feature acceptance.

## Verified composition

The initial 83-file manifest contains 78 changed sources and five unchanged
support files. Its SHA-256 is
`137951405b325ddc1b38a849269db014effee4e483e4243f43276f8d87e06580`.
It binds native5 package production, Kotlin/SAF consumer, Flutter schema6,
Gateway enrollment, and Core compatibility sources. Follow-up admission and
recovery fixes require a new manifest before copying into the completion branch.

| Root check | Result | Evidence identity |
| --- | --- | --- |
| Native/JVM composition | 177 tests; 118 RDP plus 59 Moonlight; zero failures/errors/skips | XML counts manifest `6390c68a5f7508873b03376e3a6ea819af5b2429cd49381c1a40f4dafc04928d` |
| AndroidTest Kotlin compile | Passed, 315 Gradle tasks | Log `03f196177bf1bec674471150f3ace30984234969d9d6ac0b590cf9162178a120` |
| Flutter composition | 145 passed; 26-file analysis clean | Test log `34dfb964d8446145402fbe593f3799da3ff36e48a7efe97aa6a4e48fe63394d3`; analysis `fdf3c745a60c195e5687ac0d86f6090a2a9bd5576ef152d0850f0a94b9119625` |
| Core compatibility | 25 passed; scoped Ruff clean | Log `4263478439d05130bb9b9acbbe906fbafd3504711368e0cc2e3c0a94b9afb94f` |
| Portable native5 producer contract | 22 tests / 27 subtests passed | Log `c1472b5b128fe366532c46f7695828cb40a49b522496ecbb4988d704e2a79d42` |

Both actual single-ABI AARs passed strict source/API/ELF/receipt and
verify-install checks. arm64 AAR SHA-256:
`77d5b41b069b99c2502a8aa4e692d596bd5deac8f78283c67a34b3d3d1a6c3b7`;
x86 AAR:
`9b7c764e4b9eab1675c2611f114a509366d6ba5443fc8bae0c8e42c5147f3db5`.
Both classes archives have SHA-256
`8577d42822ff525002ee25da6132450a255553f01bced7b70dfb48e51052f43b`.
The private combined product mount was verified separately; a combined AAR
is not validated by pretending it is a single-ABI package.

Core tests preserve the old seven-key profile projection and encrypted
create/update receipt replay across restart. New Gateway pins remain public,
while passwords remain scoped device secrets. Native worker publication and
retirement share an owner gate; a cancelled/focus-retired worker cannot publish
a successor session.

## Independent review and narrow follow-ups

The review found three concrete blockers before product admission:

- Both native Gateway certificate probes bypassed the product capability mask.
  Root now rejects them before compiled-runtime dispatch and always wipes the
  caller's mutable Gateway password. Core enrollment controls derive availability
  from product capabilities; pending/error/false capability results hide them,
  and scope/action checks prevent secret or Core mutation after retirement.
  The changed native bridge passed 13 actual Robolectric tests, including
  compiled-Gateway-true / product-false zero-dispatch rejection. All 23 Core
  tablet tests passed, including absence of enrollment and secret persistence.
- The SAF manager's readback recovery was not called by the production
  coordinator. Exact-owner, readback-only restart recovery is being connected;
  ambiguous evidence must remain UNKNOWN and cannot replay provider writes.
- A secret write that committed and then threw could leave an undiscoverable
  credential if deletion also failed. Durable pre-write cleanup reservation and
  restart reconciliation are being added, including the first current secret.

Admission follow-up logs: native
`bf621004e3b4292d04b9858e40e01b4ca01819395a1b9b65ff8a0f058a45a1a7`;
Flutter
`b08d57de4afa2baee73d14f47b5bb1b2e6958d612ba7e0026ae77fd6d960dc29`.
Unit fixtures do not provide accepted production effects.

The owned Gateway target also needs the real native mirror's exact `ToRemote`
upload and `FromRemote` outbound paths, rather than drive-root files. Linux
link/runtime, a real authenticated Gateway-to-target session, and packaged
Android SAF upload/save/readback are still pending. Product `rdGateway` and
`files` remain false until the required real effect evidence is admitted.

F62 stays `reworking`. Accepted totals stay 35/127 tasks and 3/63 selected
features; FINAL.FUNCTION stays active. No next final or merge is permitted by
these local results.

## Durable retirement follow-up

The exact five-source followup4 freeze was independently cleared and composed into the private root project. Its bounded deletion-only retirement index is persisted/read back before Core profile PATCH or DELETE. A fresh complete Core inventory preserves equal-revision secrets, retires only the indexed old secret after a higher revision or deletion, and rejects lower/malformed inventories. All six root Gateway admission guards remain unchanged. Root then passed 45 composed vault/tablet tests (21+24), private log SHA-256 `c87a0e3977c941673d46c5ae352bd34e717612e34d2eff0b10339c33b57ba6ab`; four-file analysis clean, log `4df41e5aaea8d711dc4a9f49ed8bb9b35189ff318c5c2beda35636ac41d09fef`. These are secure-storage/Core lifecycle test fixtures, not Android keystore process-death or live Gateway acceptance.

SAF followup2 passed 23 focused tests but independent review found two blocking gaps: manager executor termination did not prove native writer/drain completion; a cold COMPLETE ledger could admit a successor before durable mirror cleanup. Followup3 must close both with pending-native-drain and direct cold-COMPLETE-to-prepare regressions before root composition. Native5 source admission and feature acceptance remain closed.

## File receipt status propagation

The ordinary panel previously remained Prepared after its exact native close/drain returned sealed or unknown. Four EN/TR widget regressions failed on that stale text (private log `3eb3307fcee2a01610545c57f26e60fb123b5f042a6f4e6479c990aa82f0d044`). The controller now publishes the asynchronous exact-owner receipt only if its generation/scope remains current; the panel exposes localized real status. Sealed enables explicit Save; unknown does not. No automatic SAF writes occur. The focused four tests passed (`aaaaf5da4a6ce876aa4bafaf0cccf5186f099252709c31c20de41ea359c864d2`); all 75 panel/controller/schema6 tests passed (`56cdf174ecb4cbb6a758b475269511b509d7edb391a61f8b1df043ed03de9861`); five-item analysis was clean (`2f3d9f58cdf59b5e2a1d87d354abcca5874e2b98679348cc5732e30c9c8b582e`). These use UI/MethodChannel fixtures and do not establish actual Gateway, native RDPDR, or Android provider acceptance.

SAF followup3's 27 focused tests do not clear production retirement: independent review found that bridge.dispose retires/nulls the session before the coordinator's native-drain proof, synchronous close could block Activity cleanup, a timed-out callback leaves non-daemon executors running, and same-process COMPLETE cleanup can race a new prepare. A fourth private follow-up must close these through the real bridge path before composition/admission.
