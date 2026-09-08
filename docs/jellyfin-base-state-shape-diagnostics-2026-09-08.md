# Helper base state-shape diagnostics

Native run 10 (`34270629266`) used exact source
`e97189fa878863855bd6cd991d4ac6023655063e`. Both native jobs reached the
owned helper base start and failed with the same closed result:
`phase=helper_base_start code=helper_base_state_unclassified`.

The failed log was downloaded exactly once to
`/private/tmp/larenor-e97189f-native10-failed.log`: 70,215 bytes, SHA-256
`27e931c6eaa35470d68a329cfc010e34a0b99f143fc38e57a152da8fbd683f58`.
No success receipt was produced. The result proves that the single bounded
state read returned a valid typed object, but it does not identify which
remaining state shape was observed.

Commit `69215edc371505a5fb595a3aa78e473ee4f07457` divides that residual result
into four factual, closed observations:

| Closed code | Bounded observation |
| --- | --- |
| `helper_base_state_error_unclassified` | A non-empty state error matched no reviewed error family. |
| `helper_base_process_not_started_nonzero` | State was `created`, the error was empty, and the exit code was nonzero. |
| `helper_base_state_status_unclassified` | The typed status was outside Docker's reviewed status set. |
| `helper_base_state_known_status_unclassified` | The status was in the reviewed set but matched no stronger closed result. |

The final category deliberately makes no consistency or failure-cause claim.
Independent review identified Docker's valid `removing` state as a counterexample
to the first name; a real `removing` fixture and neutral label closed that P2.
Unknown errors, statuses and other known statuses preserve a stronger original
start result such as `helper_base_wait_failed`.

Four new desired outcomes first failed against the former single residual code.
The final state suite passed 28 cases, all 264 Jellyfin tests passed, and all
218 dependency-free policy tests passed. Python compilation, the security
policy check and diff validation were clean. Independent review found no open
P1/P2 issue in the final source.

The same owned container ID and socket, one 10-second/65,536-byte state read,
one start attempt, private error handling, process-group cleanup and no-retry
behavior remain in force. No raw Docker output, error text, path, URL,
environment value or identifier is emitted. Native run 11 must observe one of
the new codes; Engine and installation acceptance remain open and
`installAvailable=false`.
