# F36 fair chore Android Client slice

Status: Core and Android tablet integration complete; F36 remains `pending`
until its declared F05 and F54 dependencies close.

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

- RED `208a797b`: production Client types did not exist.
- GREEN `f283a6dd`: authority-bound controller and responsive tablet UI passed
  the initial five tests.
- RED `16843f42`: a receipt for another task could incorrectly clear an
  uncertain operation; the exact task/revision receipt check closes that gap.

- Core now derives the ordered active account set and an HMAC-bound membership
  revision inside the authenticated session. List, complete, defer and retained
  receipt endpoints reject another Core, home, account, session or membership
  authority and survive process restart.
- The Android account gateway revalidates the exact endpoint, account generation,
  Core/home identity, session family, route, lifecycle, view and window before
  every read or write. The Core home surface exposes the localized tablet route.
- Focused verification covers the durable Core reducer and real HTTP boundary,
  strict Client wire parsing, no-replay lost acknowledgement recovery, EN/TR
  600/1200 layouts, 2x text, 48dp controls, keyboard and TalkBack semantics.

Completion notification delivery remains gated by F54, and Today integration
remains gated by F05. Physical Huawei/DeX and background-delivery acceptance
stays in the MANUAL matrix. The queue remains 22/125 and selected features
remain 0/63; this integration does not advance either counter early.
