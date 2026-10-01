# Frigate owned WebSocket close lifetime — 2026-10-01

All-Server run `36820807607`, exact source
`0659ac292acae05a458550f33b142c1b2100ea2d`, completed with shards 1–3 passing
and one shard-0 failure. The F44 cancelled-refresh test failed before its
cancellation boundary: binding the provider returned the redacted
`camera_search_source_unavailable` response. The original job does not expose
the lower transport cause. A focused local repetition passed; this alone does
not establish a CI repair.

Source review found a concrete defect in the owned fixture. It sent a valid
registry result and immediately retired TCP. Production performs a final
authority guard and then sends the masked WebSocket close control frame, so
the fixture could race the actual end of the request. The new lifecycle test
first failed because the old fixture never observed that close. The fixture
now reads the bounded masked close, echoes the unmasked server close, records
the clean lifetime, and only then retires the socket. Cancellation can abort
TCP without a close frame and is not counted as a clean lifetime. Its five
second socket bound prevents a malformed owned peer from hanging the fixture.

Production transport, request deadlines, provider checks and acceptance
assertions are unchanged. Independent review found no production change
justified by this evidence. The missing fixture close is proven; its role in
the historical redacted 503 is a plausible inference, not a confirmed cause.

Root validation after the repair:

- Lifecycle, F44 normal-Core and Home Assistant WebSocket scope: **18 passed**.
- Shared F41/F42 normal-Core and private-event binding scope: **31 passed**.
- The new focused test passes the pinned Ruff check. The legacy fixture still
  has 19 pre-existing E701/E702 style findings; the added code introduces none.
- Exact diff whitespace check is clean.

New-source Ubuntu CI remains required. These are isolated owned fixtures;
no household service or device is contacted.
