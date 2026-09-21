# F52 dual-display Client contract

This first, Core-independent Android Client slice makes display ownership and
hot-plug behavior deterministic before a native `DisplayManager`/`Presentation`
adapter is connected.

| Acceptance | Software evidence |
| --- | --- |
| Route and lifecycle authority are isolated per display. | Activation requires exact account, home, session-family, route, lifecycle, interaction, topology, display-generation, and route allow-list revisions. Public secondary routes receive explicit focus and player ownership; private or unknown routes fail before the platform port is called. |
| Missing, detached, paused, or late displays fail safe. | No external display leaves the primary route in place. Detach or lifecycle retirement clears the secondary route and player ownership, dismisses its presentation, and never replays on resume. Late or malformed platform receipts cannot mutate a newer display lease. |
| The tablet/external-display model is bounded and secret-free. | Topology is limited to one primary plus four external displays. Diagnostics expose only public display status, revision, kind, and ownership facts; account, session, URL, token, credentials, and media payloads are absent. |

`dual_display_session_test.dart` covers exact authority, hot-plug retirement,
late callbacks, malformed receipts, private-route rejection, bounded topology,
and redacted diagnostics. The production contract has no Core transport or
network dependency.

F52 remains open for the native Android display bridge, real Client-to-isolated
service E2E, full-app UI/resize integration, exact-commit CI, and the separate
physical Samsung DeX/dock/touch/keyboard/protected-media acceptance. This
software fixture is not physical DeX evidence. Queue progress therefore stays
at the inherited **20/125** and selected-feature progress stays **0/63**.
