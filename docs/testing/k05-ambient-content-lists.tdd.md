# K05.remaining ambient content lists acceptance

This package extends the existing local-photo ambient display without reopening
K00–K06 foundations. Queue progress remains 22/125 and selected-feature progress
remains 0/63 until exact-head CI completes; no physical DPC or OEM acceptance is
claimed.

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
turns that decoder error into one generation-bound playlist completion, shows
no library or stack-trace detail, and advances to the next verified item. A
retired route cannot use a late decoder error to advance a replacement item.
