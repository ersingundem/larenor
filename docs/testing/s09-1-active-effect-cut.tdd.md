# S09.1 externally visible effect cut

Date: 23 September 2026

This slice starts from the current `origin/main` and changes neither the open
component-worker runtime/config files nor the concurrent music-retained Client
files.

## Three delivered jobs

1. A Proxmox power request whose latest journal state is `accepted` or
   `executing` blocks backup capture. The query considers only the latest row
   for each request, so a later terminal receipt leaves history intact without
   blocking future backups.
2. An accepted kiosk remote command blocks capture until its exact command row
   is completed. This prevents a portable database cut from claiming
   consistency while the managed tablet can still apply an external effect.
3. A Music Assistant key rotation blocks capture in both `preparing` and
   `activated` states. `activated` remains nonterminal because the previous key
   has not yet been retired. A `retired` rotation does not block.

The three blocker codes are part of the strict response model and one stable
public order. They contain no request ID, device ID, journal content, key
material, path, or provider data. Component quiescence remains mutually
exclusive with active-effect blockers under the existing plan contract.

## RED to GREEN evidence

The first focused run produced **5 failures and 3 passes**. Every unfinished
effect incorrectly returned `status=ready` with a manifest, while all terminal
history cases already passed.

The final focused batch is:

```sh
cd server
uv run --locked --no-sync python -m pytest \
  tests/test_core_backup_active_effect_cut.py \
  tests/test_core_backup_contract.py \
  tests/test_core_backup_plan_blocker_contract.py \
  tests/test_core_backup_components.py -q
```

Result: **35 passed**. The batch covers the five active states, three terminal
histories, combined deterministic ordering, existing effect blocking,
quiescence exclusivity, and component capture.

## Remaining S09.1 gates

S09.1 remains pending. The privileged component snapshot worker review,
component restore/rollback and interruption recovery, large-volume native
acceptance, independent review, and exact-head CI remain open. This slice does
not change `docs/execution-queue.json`, task status, or the evidence-backed
counters **26/125** and **0/63**.
