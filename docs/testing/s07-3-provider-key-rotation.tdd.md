# S07.3 Music Assistant private key rotation — TDD evidence

Source: the S07.3 audit gap for a private Music Assistant credential rotation.
This slice adds no HTTP endpoint and does not change the 17/125 queue or 0/63
feature counters. Physical receiver validation and the S07.1 dependency remain
open gates.

## Exactly three acceptance criteria

1. A Core worker can rotate the private Music Assistant key only under the
   exact Core, home, account, session family, installation, worker revision,
   provider revision, and provider instance. The authenticated replacement and
   journal phase change commit atomically.
2. The previous key remains active until the replacement produces an
   authenticated readback. A committed intent survives a lost reply or process
   restart and reconciles idempotently without creating a second key or
   repeating a confirmed retirement.
3. Rollback, encrypted-journal tampering, a foreign session family, provider or
   worker drift, and concurrent rotation fail closed. Tokens stay inside
   encrypted private models and are absent from public HTTP/OpenAPI state,
   exceptions, model representations, and plaintext database dumps.

## RED → GREEN evidence

| Acceptance | Test | Type | Evidence |
|---|---|---|---|
| 1 | `test_rotation_is_atomic_and_exactly_bound_to_core_session_worker_and_provider` | integration | RED: import failed because the rotation contracts did not exist. GREEN: prepare sees the old key; retire sees revision 2 and the authenticated replacement. |
| 2 | `test_lost_responses_restart_and_replay_reconcile_without_duplicate_rotation` | restart integration | Two lost replies and two `create_app` restarts reconcile `preparing → activated → retired`; replay returns the same receipt and never repeats prepare/retire. |
| 3 | `test_rollback_tamper_foreign_session_and_concurrent_rotation_fail_closed` | adversarial security | Exact binding drift and foreign family are rejected, an active second request conflicts, ciphertext tampering blocks startup, and secret strings are absent from SQLite/public output. |

RED command:

```text
/Users/ersingundem/oikos/server/.venv/bin/python -m pytest -q tests/test_music_assistant_key_rotation.py
ImportError: cannot import name 'AuthenticatedMusicAssistantKeyRotationReadback'
```

GREEN focused command:

```text
/Users/ersingundem/oikos/server/.venv/bin/python -m pytest -q \
  tests/test_music_assistant_core_wiring.py \
  tests/test_music_provider_setups.py tests/test_music_provider_commands.py \
  tests/test_music_playback.py tests/test_music_assistant_key_rotation.py
54 passed
```

Coverage, compile, queue, security, gitleaks, diff, and merge-tree commands are
recorded in the final branch verification after the current main rebase. The
focused branch-coverage run over the three changed Core modules reports 81%
across 54 passing tests (312/47/33 statements in management/models/schema).
