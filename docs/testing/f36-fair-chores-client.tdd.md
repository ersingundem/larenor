# F36 fair chore Android Client slice

Status: independent Client contract and tablet surface; F36 remains `pending`.

## Three accepted criteria

1. The controller binds every read and mutation to the exact Core, home,
   account, session, and route lease. Route replacement/disposal clears tasks;
   late list or mutation responses from the prior lease cannot become current.
2. Complete and one-day defer use the exact task revision and a single command
   id. A lost acknowledgement enters an uncertain state: the Client reads the
   receipt by id and never sends the mutation again. Authority, action, task id,
   command id, and next revision must all match before a receipt is accepted.
3. The standalone tablet surface exposes current assignment, due time, defer,
   completion, loading/empty/offline/error/uncertain states, EN/TR injected
   labels, 600/1200 layouts at 2x text, 48dp actions, TalkBack labels, and Enter
   or Space keyboard activation.

## Evidence and remaining integration

- RED `0d3237da`: production Client types did not exist.
- GREEN `187791ed`: authority-bound controller and responsive tablet UI passed
  the initial five tests.
- RED `4ee9cbe4`: a receipt for another task could incorrectly clear an
  uncertain operation; the exact task/revision receipt check closes that gap.

The authenticated HTTP implementation, app route/AppLocalizations adapter,
real household-member names, notification delivery, and Client-to-isolated-Core
E2E stay open. This slice touches no global route or localization files, so it
can merge independently from the current F54 and tablet pull requests. The
queue remains 18/125 and selected features remain 0/63.
