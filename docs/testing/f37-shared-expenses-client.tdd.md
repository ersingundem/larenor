# F37 shared expenses Android Client slice

Status: stacked on the local F37 Core foundation; F37 remains `pending`.

## Three accepted criteria

1. The create surface parses locale decimal separators into integer minor units,
   rejects ambiguous precision, sorts selected participants deterministically,
   previews every share, and verifies that the shares preserve the exact total.
2. Snapshot, create, receipt reconciliation, and export bind to the exact Core,
   home, account, session, and route lease plus ledger/member revisions. Route
   replacement clears retained data; stale replies fail closed. Lost create
   acknowledgement is reconciled by command id without replaying the write.
3. History and export are read-only. Export accepts only the current ledger
   revision and records where the current account is payer or participant. The
   EN/TR surface works at 600/1200 widths with 2x text, scrollable reflow, 48dp
   actions, labeled form controls, button semantics, and live status copy.

## Evidence and open integration

- RED `009373c4`: the production Client module did not exist.
- GREEN `4b79a8d0`: five controller/widget scenarios passed for split, authority,
  uncertain receipt, responsive UI, history, and read-only export.
- RED `32ef66e2`: a foreign participant export was retained; `a512295f` rejects
  it and disables create outside a current ready/empty authority state.

The authenticated HTTP adapter, app route/AppLocalizations adapter, current
household resolver, persisted export artifact, edit/reversal journal, and real
Client-to-isolated-Core E2E remain open. No progress counter changes are claimed.
