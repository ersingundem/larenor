# F58 e-paper mini-home-screen Core acceptance

This package establishes a fail-closed Core snapshot and delivery boundary for
small e-paper displays. Queue progress remains at 20/125 and selected-feature
progress remains at 0/63. Durable snapshot storage, authenticated device HTTP,
bridge adapters, Android management UI, remote erase semantics, and physical
e-paper hardware acceptance remain explicit delivery gates.

Exactly three user acceptance criteria are in scope:

1. A user can publish only shared weather, energy, temperature, clock, or
   battery cards with an allowlisted two-to-four-color layout. The snapshot is
   bound to exact Core, home, device, bridge, layout, data, provider, and policy
   revisions, has a bounded TTL, rejects secret-like content, and produces the
   same render digest for the same canonical inputs.
2. An offline display can pull the current bounded snapshot and retry the same
   request idempotently. A complete acknowledgement becomes verified only when
   every frame, byte length, digest, device, layout, data, and policy revision
   matches the currently resolved sources.
3. Publishing a newer snapshot immediately clears the previous verified state.
   A partial acknowledgement remains partial, and expired or revision-drifted
   snapshots cannot be pulled, acknowledged, or presented as verified.

## TDD evidence

The RED commit `6f8bc079` failed collection because the
`larenor_server.epaper_snapshots` package did not exist. The GREEN matrix has
exactly three focused tests covering allowlists, deterministic canonical
rendering, all revision and TTL boundaries, secret rejection, offline pull and
idempotent exact acknowledgement, source drift, partial delivery, and expiry.
