# F59 workshop printer integration acceptance

Validated on 21 September 2026. The software boundary is intentionally limited
to status monitoring and reviewed pause/cancel intents. A retained receipt says
`notDispatched`; it is never presented as printer execution.

## Three acceptance criteria

1. **Persistent, authenticated authority.** Core retains HMAC-protected printer,
   job, material, safety and receipt state across restart. OctoPrint `/api/version`
   and Moonraker `/server/info` probes authenticate only with the stored API-key
   handle, use fixed read-only requests and never expose provider replies or
   credentials through the public printer projection.
2. **Explicit intent and readback.** Exact Core/home/account/session/route,
   printer/job/service/material/safety revisions authorize a bounded pause or
   cancel preview. A separate confirmation records one idempotent receipt; the
   Client reads that receipt back from retained history. Lost responses, stale
   callbacks and unknown provider state fail closed without automatic replay.
3. **Tablet control surface.** Settings exposes the route behind its current
   administrator/PIN/lifecycle gate. EN/TR layouts at 600 and 1280 logical pixels
   with 2x text keep 48dp controls, keyboard activation and labelled TalkBack
   semantics while hazards remove actions.

## Automated evidence

- Server: 167 focused tests passed across F59 Core, service probes and service
  management.
- Flutter: 27 focused API/controller/widget/route/service/settings tests passed.
- Focused Flutter analyze, Ruff, repository security, queue/progress, gitleaks,
  diff and merge-tree checks are part of the final handoff gate.

## Manual acceptance

Real printer execution/readback and physical Android tablet, Huawei MatePad and
Samsung DeX behavior remain manual. The provider command worker is deliberately
absent, so this slice cannot claim that a recorded intent reached hardware.
