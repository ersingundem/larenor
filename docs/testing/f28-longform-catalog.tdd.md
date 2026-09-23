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

- RED `a227b140`: the public Core long-form models and route did not exist.
- RED `b834f244`: the authenticated runtime and fresh-detail path did not
  exist.
- GREEN `31fbef6b`: 24 focused manager, runtime, authority and IPC tests pass.

F28 remains pending at **26/125 (20.8%)** and selected-feature progress remains
**0/63 (0.0%)**. Client rendering, chapter selection, bookmarks, sleep timer,
MediaSession/background behavior, provider capability disclosure, a real
isolated Music Assistant fixture and full exact-head CI are still required.
