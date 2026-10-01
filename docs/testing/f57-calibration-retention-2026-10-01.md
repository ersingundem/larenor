# F57 calibration receipt retention evidence

Date: 2026-10-01

## Authenticated boundary

Room-presence state is stored as one AES-GCM authenticated encrypted document.
Before retention can select a receipt, decoding validates the complete device,
preview, receipt, authority, revision, and parent relationship. A linked receipt
whose authority or calibration facts differ from its preview makes the store
invalid; ciphertext modification fails AES-GCM authentication. Historical v1
receipts created after an older release had already removed their preview parent
are migrated to state schema v2 with a conservative authenticated timestamp
equal to migration time. The same conservative time applies to linked v1
receipts because confirmation could have happened at any point before preview
expiry. They remain protected for a full inclusive 24 hours after migration
before becoming terminal retention candidates; migration does not invent a
missing parent relationship. Container types are checked before conversion.

New receipt-backed previews stay linked. Retention preserves every unresolved
`uncertain` receipt, the receipt that proves each device's currently installed
calibration revision, all receipts whose authenticated recording time is on or
after the inclusive 24-hour cutoff, and the 32 newest terminal receipts.
Uncertain receipts do not consume those 32 terminal replay positions. Only older
`applied` or `rejected` receipts, their available preview parents, and expired
untouched previews are candidates.

Capacity calculation happens after current actor, route, home, device, policy,
consent, room, and calibration authority checks. Candidate removal, the new
preview or receipt, the calibration revision change, and encrypted persistence
form one repository mutation. A persistence failure reloads the prior encrypted
document, so no candidate disappears without the replacement operation.
Unresolved receipts can intentionally keep the 256-record store full.

Calibration confirmation changes only Larenor's advisory calibration revision;
there is no provider calibration write. Exact replay returns the stored receipt
before retention and cannot increment the revision or call Home Assistant.

## Focused evidence

```text
cd server
.venv/bin/python -m pytest -q \
  tests/test_f57_room_presence_retention.py \
  tests/test_f57_room_presence_http.py \
  tests/test_f57_mqtt_room_normal_core.py \
  tests/test_f57_room_presence_fusion.py
```

Result: 30 tests passed. The retention cases fill the real default 256-record
cap, cross a Core restart, reclaim old history, preserve exact recent replay and
current calibration, and reject replay of pruned history. They also cover the
inclusive 24-hour boundary, uncertain-cap rejection, authenticated parent
mismatch, ciphertext tampering, conservative v1 orphan migration, write-failure
rollback, invalid v1 container rejection, 30 uncertain receipts alongside a
separate 32-terminal replay window, and an owned loopback Home Assistant
MQTT-room source whose request trace is unchanged by confirm and exact replay.

## Limits

Presence remains advisory and grants no physical access. A Home Assistant
observation proves only the configured provider read. Calibration receipts do
not prove a mmWave device was physically reconfigured, because this product
flow does not issue such a provider command.

Root independently passed all30cases with live working-tree source: `PYTHONPATH=server server/.venv/bin/python -m pytest server/tests/test_f57_room_presence_retention.py server/tests/test_f57_room_presence_http.py server/tests/test_f57_mqtt_room_normal_core.py server/tests/test_f57_room_presence_fusion.py -rA --tb=no`. Result30passed,0failed,0skipped,2warnings,27.84seconds; private log `/private/tmp/larenor-f57-retention-root.log`. This includes the corrected delayed-confirm migration boundary, invalid v1 container rejection and mixed uncertain/terminal retention cases. No physical mmWave write is claimed.
