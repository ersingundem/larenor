# F59 workshop printer Core foundation

21 September 2026. This first software slice creates a closed Core contract for
monitored OctoPrint and Moonraker printers. It records reviewed pause or cancel intents; it
does not dispatch commands, accept arbitrary G-code, expose file paths or read
service credentials through a public model.

## Three acceptance criteria

| Criterion | Evidence |
| --- | --- |
| Printer, job, material and safety snapshots use independent exact revisions, remain bound to an authenticated OctoPrint/Moonraker service revision and survive restart without exposing its API key | `test_printer_job_material_and_safety_revisions_are_exact_and_secret_free`, `test_octoprint_and_moonraker_share_a_secret_free_provider_boundary` |
| Only a current administrator can preview and confirm a bounded pause/cancel intent; byte-exact request identity gives one HMAC-authenticated receipt, and a late/lost acknowledgement only reads that receipt without dispatching again | `test_admin_preview_confirm_is_bounded_idempotent_and_never_dispatches` |
| Offline, stale, thermal runaway, filament runout, open-door and emergency states suppress every action before an intent is recorded | `test_hazard_offline_or_stale_state_blocks_every_intent_fail_closed` |

The RED contract failed all three tests before `octoprint` service support and
the workshop route existed. The GREEN gate passes the three new acceptance
tests and the existing service-management suite. Both persistent tables use
strict schema validation and HMAC envelopes; mutation is detected during reads
and restart. Preview capacity is bounded globally and per actor, safety data is
fresh for at most 30 seconds, and confirmed history is capped at 10,000 rows.

Real OctoPrint/Moonraker observation, camera/thermal hardware, printer connectivity and
physical pause/cancel readback remain manual integration acceptance. F59 stays
pending until the isolated command worker and physical device gates are complete.
