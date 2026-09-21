# F40 shared resource reservation Core foundation

Status: **software foundation delivered; F40 remains pending**

This package establishes the server-owned calendar contract without depending
on F39 files or claiming the later Client-to-Core acceptance journey. It does
not use a production home, account, calendar, or secret.

## Three accepted criteria

1. **Bounded time and capacity model.** A resource has an exact IANA timezone,
   revision, capacity and member set. Create commands use local wall time,
   explicit DST fold, a duration of at most one day and at most 64 daily or
   weekly occurrences within 366 days. Nonexistent local times fail closed;
   ambiguous folds resolve to deterministic UTC instants. A serialized SQLite
   write transaction checks aggregate units across every overlapping existing
   and proposed occurrence, so one capacity limit produces one result.
2. **Exact authority and command identity.** Create and cancel commands bind
   the Core, home, account, member, resource and calendar revisions with exact
   JSON scalar types. A command identifier replays only for the same actor,
   action and byte-exact request fingerprint; changed whitespace, fields or
   action returns an idempotency conflict. Every accepted mutation advances the
   calendar revision and a keyed event/state chain covers actor, action,
   resource, request fingerprint, result revision and previous event.
3. **Encrypted, role-scoped reads and cancellation.** Reservation details and
   occurrences are AES-256-GCM encrypted at rest with scope-bound associated
   data. Keyed payload fingerprints and strict schema markers detect tampering
   after restart. Resource members and administrators may read bounded
   availability/history/export; only the owner or administrator may cancel.
   Availability exposes busy windows and units only, and exports contain no
   command bytes, cryptographic keys, nonces, ciphertext or fingerprints.

## TDD and verification evidence

- RED `e99aed5a`: the module import failed before any production code existed.
- GREEN `6fa92331`: schema, encrypted store, recurrence, authority,
  idempotency, cancellation, availability and export contracts were added.
- Adversarial repair `361a1b33`: a RED aggregate-capacity case showed that
  pairwise checks could overbook a capacity-three resource. The repair sums all
  concurrent units, rejects numeric lookalike revisions, uses keyed request and
  payload fingerprints, and reads audit state from one SQLite snapshot.
- `PYTHONPATH=server .../python -m pytest -q
  server/tests/test_f40_resource_reservations.py`: 3 passed.
- Python bytecode compilation, repository security policy, execution queue,
  progress trailer validation, diff whitespace checks, redacted secret scan
  and merge-tree verification are required again at the final package head.

## Honest remaining boundary

F40 stays pending at the existing progress count. The versioned HTTP surface,
Android tablet calendar, isolated Client-to-Core E2E, concurrent multi-process
fixture and physical tablet evidence remain separate follow-up packages. The
foundation never treats a calendar provider read as authority to mutate this
Larenor-owned schedule.
