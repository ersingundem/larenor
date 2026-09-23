# K05.remaining ambient content lists acceptance

This package extends the existing local-photo ambient display without reopening
K00–K06 foundations. Exact-head CI and independent review are complete, so
queue progress is 25/125 while selected-feature progress remains 0/63. No
physical DPC, decoder, display or OEM acceptance is claimed.

Exactly three user acceptance criteria are in scope:

1. A user can explicitly select bounded local MP4/PDF files or approve an HTTPS
   page. The private manifest retains no picker path, username, password, query
   or fragment; local copies are digest verified, limited to 24 items and 256
   MiB total, and web navigation remains on the approved origin without
   same-origin query or fragment redirects.
2. The ambient playlist loads one item at a time, skips a corrupt entry and
   continues, uses the existing bounded WebPanel policy, disables video motion
   when reduced motion is enabled, and retires timers, players, reads and web
   callbacks when the route, window or app lifecycle is no longer active. The
   existing media ownership lease continues to prevent idle overlay while user
   media is active.
3. The EN/TR settings surface exposes 48dp keyboard/TalkBack actions for video,
   PDF and web selection at 600 and 1280 logical pixels with 2x text. File picker
   and confirmation results are accepted only by the exact current interaction;
   removal and web origin grants require explicit confirmation.

## TDD evidence

The RED commit `33d5f6cb` failed because the content domain, repository,
playlist and settings surface did not exist. Focused GREEN tests cover strict
format/origin validation, offline quota and digest readback, corrupt-item skip,
lifecycle retirement, exact-origin redirects, reduced-motion behavior, and the
four-locale/size accessibility matrix. Existing ambient/photo, idle media lease
and WebPanel suites remain regression gates.

Follow-up race regression: the outgoing item's completion callback and callbacks
from a retired playlist generation cannot advance the new item. Video native
open is paused by default, and foreground/route authority is checked again after
muting, opening and playing; a late return pauses playback. The first stale-item
callback test failed before the fix and passes afterward. Physical decoder and
OEM display acceptance remains manual.

Follow-up URL regression: an approved ambient page previously inherited the
general WebPanel same-origin policy, which allowed later query/fragment
navigation even though the ambient source rejected those addresses on import.
Ambient content now requests a clean-navigation policy while ordinary WebPanel
pages retain their existing behavior. Repository and WebView delegate tests
cover same-origin secret-bearing redirects.

Follow-up decoder regression: a digest-valid file could still fail inside the
PDF decoder after the repository's bounded container checks. The viewer now
turns that decoder error into one generation-bound playlist failure, shows no
library or stack-trace detail, and advances to the next verified item only once
per content pass. A single broken item and an all-broken list stop on the safe
placeholder after each item has been tried once. A retired route cannot use a
late decoder error to advance a replacement item.
Manifest readback now also rejects a local item's claimed size when it exceeds
that format's individual limit. Regression coverage fills the library to its
24-item and 256 MiB offline ceilings before proving the next import fails. The
quota is reconciled against regular managed files before every local import:
stale managed orphans are removed, while missing, wrong-sized or non-regular
manifest backing files fail closed. This prevents interrupted imports from
growing the physical cache beyond the declared limit.

## Exact-head acceptance

Commit `9431c9115e3a04221ef4bc7e2926c1b1f9f501c3` passed 79 ambient tests,
the 67-test ambient/settings/lifecycle acceptance package, focused analysis,
and independent review of decoder retry, physical quota, authority and stale
callback boundaries. Android Build run `35821461533`, including API 35 app
journeys and the debug APK, and Security run `35821461367` both passed on that
same source commit. Physical decoder, display and OEM behavior remains a manual
release gate.
