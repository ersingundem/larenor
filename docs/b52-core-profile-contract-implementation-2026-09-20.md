# B5.2 — Account-scoped Core remote profile contract

21 September 2026. This independent Server slice supplies the Core contract for
managed remote profiles. It intentionally leaves device-local personal profiles
and credentials on Client and does not complete B5.2 or S08.11.

## Acceptance matrix

| Acceptance | Implemented boundary | Evidence |
| --- | --- | --- |
| Exact Core authority and separation | Every public reference is a `coreRemoteProfile`, never a local personal profile. Responses bind exact Core, home, account, current session family, account revision and collection revision. Repository reads and mutations always include the owner account; administrator status grants no cross-account access. | Two real accounts and two independent session families prove isolation, wrong Core/home rejection, opaque 404 behavior and restart durability. |
| Idempotent, stale-safe operations | Create, update and delete take a caller request ID plus exact account and collection revisions; read also takes exact profile revision. Encrypted receipts make exact retries deterministic within the originating session family. Changed, evicted, late, foreign-family and old-state replays fail closed without reapplying a mutation. | Exact create/update/delete and restart replays, changed-payload conflict, stale read/update/delete, foreign-family replay, bounded receipt eviction and no-partial-write tests. |
| Confidential, bounded, tamper-evident persistence | The contract has no credential, token, secret, PIN, key or lease field. Allowed metadata and receipts use AES-GCM with scoped AAD. Collection state and the bounded audit journal have keyed authentication; startup validates record counts, receipt limits, row tags and a digest of the retained journal. | Six adversarial forbidden-field requests; OpenAPI/log/schema/dump checks; encrypted record, receipt, journal-row and journal-state tamper restart failures; profile and receipt bound tests. |

## API and ownership

`/api/v1/core-remote-profiles/{core_id}/{home_id}` exposes typed list/create and
`/{profile_id}` exposes typed read/update/delete. All operations use the existing
ready-user dependency, current-session database assertion, request boundary,
static error map and rate limiter. Idempotency receipts are scoped to the exact
account and session family. A successful old operation is not projected over a
newer collection revision. There is no admin collection, grant endpoint,
command endpoint or reusable authorization lease.

Only connection metadata needed to identify a remote target is accepted:
label, SSH/RDP/VNC protocol, normalized host, port and optional username.
Credentials, host trust, private keys, commands, PIN state and Client session
leases remain outside this repository. The Client must still use its local PIN,
route, lifecycle and one-resource lease gates before opening a connection.

## Verification

- Core remote profile API/security suite: **17 passed** with **90%** focused
  line coverage (442 statements; 80% gate).
- Core context and v1 migration regression joined to that suite: **48 passed**.
  The v1 fixture removes every post-v1 profile table and marker before
  migration, so the new authenticated state is rebuilt against the migrated
  Core/home identity instead of retaining a synthetic stale tag.
- Related authentication, administration, Core context and home-resource
  regression: **129 passed** on the current base.
- Python compile, execution queue validation, diff check and gitleaks are
  recorded with the wrapper commit.

## Client dependency

PR #223 merged as `900fe81d` and supplies the required Client-side proof for
device-local profile separation plus PIN, background, idle, route and
bounded-resource retirement. This Server contract is rebased on that authority.
The dependent Client synchronization slice remains a separate review and CI
gate.

Physical targets, Client synchronization, multi-Core discovery and S08.11
central search remain separate acceptance gates, so roadmap counters do not
advance in this commit.
