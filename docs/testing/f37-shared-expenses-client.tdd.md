# F37 shared expenses Android Client slice

Status: authenticated Core-to-Android integration is implemented; F37 remains
`pending` until its edit/reversal journal, downloadable CSV artifact, and real
tablet-to-isolated-Core acceptance are complete.

## Three accepted criteria

1. The create surface parses locale decimal separators into integer minor units,
   rejects ambiguous precision, sorts selected participants deterministically,
   previews every share, and verifies that the shares preserve the exact total.
2. Snapshot, create, receipt reconciliation, and export bind to the exact Core,
   home, account, session, and route lease plus ledger/member revisions. Route
   replacement clears retained data; stale replies fail closed. Lost create
   acknowledgement is reconciled by command id without replaying the write.
3. History and export are read-only. Export accepts only the current ledger
   revision and participant/payer records, or the full ledger when the Core
   explicitly grants admin-wide visibility in the exact authority. The
   EN/TR surface works at 600/1200 widths with 2x text, scrollable reflow, 48dp
   actions, labeled form controls, button semantics, and live status copy.

## Evidence and open integration

- RED `009373c4`: the production Client module did not exist.
- GREEN `4b79a8d0`: five controller/widget scenarios passed for split, authority,
  uncertain receipt, responsive UI, history, and read-only export.
- RED `32ef66e2`: a foreign participant export was retained; `a512295f` rejects
  it and disables create outside a current ready/empty authority state.
- RED `08a1ddf1`: the Core's admin-wide export was rejected by the Client's
  participant-only filter. The authority now carries explicit Core-confirmed
  visibility; ordinary accounts still reject foreign records.
- RED `c994dcda`: a foreign snapshot could be rendered and a failed refresh
  retained the previous ledger. The Client now clears prior ledger data before
  refresh and rejects records outside the current account's visibility.

- `089bc63f` exposes the authenticated Core contract with the live account
  membership resolver, HMAC-bound membership revision, idempotent command
  receipts, and participant-filtered export.
- The Android route now retires data on account, session, home, route, window,
  lifecycle, or focus replacement. It uses localized EN/TR copy and requires an
  explicit retry after a failed connection instead of reconnecting in a loop.

The downloadable CSV artifact, edit/reversal journal, and real
Client-to-isolated-Core device acceptance remain open. No progress counter
changes are claimed.
