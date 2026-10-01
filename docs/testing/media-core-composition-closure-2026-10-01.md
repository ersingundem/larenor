# F21/F24–F27 implementation closure — 1 October 2026

The normal verified-Core catalog now exposes explicit on-device playback and
retains managed remote playback separately. Its player composes current
watch-party controls, actual emitted audio/subtitle choices, exact-catalog
segment skip, non-recording quality advice, and an encrypted offline source.
Completed offline downloads also have their own account entry while Core is
unavailable; this uses a token-free decryption scope rather than API authority.

The original [composition-gap review](f24-f27-player-core-composition-gap-2026-10-01.md)
is historical. Its ordinary-entry and cold-start blockers are closed by these
source slices:

| Source commit | Change | Named evidence |
| --- | --- | --- |
| `7a365e22a601e7e14ec6df2ac6519fb17fd326cc` | Exact Core-bound source, ordinary catalog entry and actual player controls | [Core player](f21-f24-f25-f27-core-local-player-2026-10-01.md), root 38 tests |
| `a7713f93e996efc418078f5e666460e6144179c6` | Actual track selection, current-only persistence, invitation/transfer/leave and bounded native effects | [Session controls](f21-f24-core-player-session-controls-2026-10-01.md), 13 player tests |
| `6fc7cb82c9b13fe8f9c6b69c882bc79f7ecf9d37` | Separate completed-download inventory/player and offline account navigation | [Offline player](f27-offline-downloads-local-player-2026-10-01.md), root 46 tests |
| `d8bbc13092991922cf8d96dff3e629ff166296d6` | Non-recording `assess-item`, separate consumable `observe-item` and preserved explicit lease capacity | [API/provider proof](f26-non-recording-quality-advice-2026-10-01.md), root 46 Server tests |
| `0f5143006f7bb359fba1e4b3f3e59134134db1d8` | Closed Client advice contract, cancellable panel deadlines and correctly labelled on-device entry | [Quality panel](f26-core-catalog-quality-panel-2026-10-01.md), root 110 Client tests |

Root's final 110-test combined gate passed with exit 0 after the label and
intro correction. It includes capability, Core source, actual player,
ordinary catalog, unified Core track preferences, offline inventory,
connection navigation, encrypted-vault loopback and Core loopback suites.
The independent implementation review also checked the feature plan and
existing normal-Core restart/protocol gates. No remaining software
composition blocker was found for F21, F24, F25, F26 or F27.

These five items therefore move to **CI waiting**, not accepted/done. The
accepted counters remain **35/127 tasks** and **3/63 selected features**.
The live queue now has **69 tasks / 58 selected features waiting for CI**.
Only F60/F62 remain in rework and only FINAL.FUNCTION is active.

The exact final branch HEAD still needs broad Server/Android/Security CI.
Physical multi-receiver timing, subtitle rendering, segment accuracy,
HDR/decoder/network performance, storage pressure and provider/DRM permission
remain in their separate manual gates. These software tests do not certify
household services or physical audio/video.
