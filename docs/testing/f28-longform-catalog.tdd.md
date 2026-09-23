# F28 long-form catalog Core slice

This slice adds the first secret-free Larenor Core contract for Music
Assistant audiobook and podcast progress. It does not declare F28 complete.

## Three delivered contracts

1. A ready household member can request at most 25 in-progress audiobooks or
   podcast episodes through the existing revision-bound Music Manager. The
   public response contains only the opaque media URI, display name, type,
   provider instance, duration, resume position, completion state and bounded
   chapters. Music Assistant credentials never cross private IPC.
2. The private runtime first reads `music/in_progress_items`, then obtains
   fresh `music/item_by_uri` details for every returned identity. A mismatched
   URI/type, duplicate item, invalid duration/progress, unsafe text, more than
   512 chapters, invalid chapter order or an HTTP media URL closes the entire
   read without publishing partial data.
3. Core binds the request and every callback to the exact installation,
   installation revision, Music Assistant Core revision, manager revision and
   provider bindings. A timeout, throwing gate or authority drift after the
   worker read discards the result. The same strict models cross the private
   Unix-socket worker boundary.

The upstream contract is based on Music Assistant's documented
[`music/in_progress_items` and `music/item_by_uri` commands](https://www.music-assistant.io/api/)
and its documented audiobook chapter metadata and resume behavior.

## TDD evidence

- RED `d48ce783`: the public Core long-form models and route did not exist.
- RED `4e0f7dc7`: the authenticated runtime and fresh-detail path did not
  exist.
- GREEN `55c52383`: 24 focused manager, runtime, authority and IPC tests pass.

The independent exact-head audit added RED `c0613881`: an item from an
unbound provider instance, falsey malformed metadata containers and
overlapping chapter boundaries were accepted. GREEN `1a10a2c4` carries the
exact ready provider-instance set through private IPC, validates every detail
against it, preserves strict container types and rejects overlapping chapter
ranges. RED `017471e1` then exercised matching summary/detail HTTP identities,
which the general URI regex had allowed; GREEN `7152b874` rejects external,
local and executable URI schemes plus control characters before publication.
RED `9ab7aed2` and GREEN `d3ca9143` additionally close custom-scheme query,
fragment and user-info metadata channels, including token-shaped values.
The expanded manager/runtime/authority batch passes **28/28**; Ruff F,
security policy, execution-queue validation and diff checks are clean.

F28 remains pending at **26/125 (20.8%)** and selected-feature progress remains
**0/63 (0.0%)**. Client rendering, chapter selection, bookmarks, sleep timer,
MediaSession/background behavior, provider capability disclosure, a real
isolated Music Assistant fixture are still required. Independent review and
all required exact-head checks passed on `92253ca1`, which merged as
`38cefa3a`; those completed evidence gates are no longer remaining work.

A final current-main audit added RED `4d04119257ddc7469bd49838c7169a084e4d161c`: a typed private-worker result
could escape the captured provider bindings or repeat one media URI and still
be published by Core. GREEN `e34f3468c962e597b0bce22a0ebf0aea89756371` revalidates provider ownership and URI
cardinality before the final authority gate. The expanded manager/runtime/F28
batch passes **29/29**.
