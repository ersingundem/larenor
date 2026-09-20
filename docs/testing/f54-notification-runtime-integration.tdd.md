# F54 foreground notification runtime acceptance

This slice joins the authenticated Core inbox, Android renderer, and root
Client lifecycle. Delivery remains `foregroundPull`; it does not claim
background, Doze, OEM wake-up, or physical-device acceptance.

| Acceptance | Production boundary | Automated evidence |
| --- | --- | --- |
| One bounded foreground authority | The application-scoped coordinator runs only for a verified Core, exact account/home/session, active home interaction, resumed and focused window. A one-minute timer cannot overlap a pull or native reconciliation; source, account, lifecycle, or focus retirement closes the old controller work. | Loopback HTTP tests hold a pull behind a barrier across multiple timer ticks and observe one request. Late readback after retirement cannot navigate. |
| Permission and privacy remain explicit | Startup only probes Android state. Permission is requested from the visible user action; denial is retained and the UI changes to Settings rather than prompting again. The exact system-dialog focus handoff may complete, while lifecycle/account retirement rejects it. Only Core's public projection reaches native code. | Dart coordinator/channel/widget tests cover no implicit request, the bounded focus handoff, redaction, EN/TR and 600/1200 at 2x text. Robolectric covers the real focus transition, denial, no re-prompt, and private lock-screen rendering. |
| Tap routes only after authoritative readback | A tap must match the SHA-256 account binding, current subscription revision, event ID, and sequence. The Client ACKs Core, performs exact readback, verifies the event is read, and only then applies the allowlisted route. Duplicate, late, stale, unknown, and replayed taps are discarded. | Loopback tests cover stale revision, ACK/readback order, duplicate suppression, and late authority loss. Native tests cover one-use tap nonces and persisted replay high-water state. |

F54 still needs a separately accepted background transport/device gate if that
scope is desired. Queue progress therefore remains **17/125** and selected
feature acceptance remains **0/63**.
