# Helper base state-read diagnostics

Native run 9 (`34267014037`) used exact source
`63b25f8c36b9973cf5a691aa7e45726add2a58a9`. Both native jobs failed before
producing a success receipt with the same closed result:
`phase=helper_base_start code=fixture_command_exit_failed`.

The failed log was downloaded exactly once to
`/private/tmp/larenor-63b25f8-native9-failed.log`: 70,203 bytes, SHA-256
`85f0cd8e7c8308e42062b00eeaf9870f4d99c328d822a1169b7fd64fe8384076`.
The prior zero-state reducers did not match. This result does not establish
whether the owned `.State` read failed, returned an invalid response, or
returned a valid but unclassified state.

Commit `560c756e99102b8f326067a60aee2f81dc0914e2` distinguishes those three
observations only when the original start result is the generic
`fixture_command_exit_failed`:

| Closed code | Bounded observation |
| --- | --- |
| `helper_base_state_read_failed` | The one owned state command did not produce a bounded successful response. |
| `helper_base_state_invalid` | The bounded response was not a valid, typed state object. |
| `helper_base_state_unclassified` | The typed state was valid but matched no existing closed state or error family. |

A more specific existing start result such as wait, timeout, permission or
runtime failure survives an unreadable or invalid state response. No raw
Docker output, error text, path or identifier is emitted. The same owned
container ID and socket, one 10-second/65,536-byte inspect, one start attempt,
whole-daemon cleanup and no-retry behavior remain in force.

The first implementation produced six real RED state assertions. Broader
tests then caught the required precedence rule for specific start results.
Independent review found that an unpaired Unicode surrogate or recursive JSON
decoder failure could escape the narrowed validation block; two surrogate RED
cases and an explicit recursive-decoder seam closed that P2 without catching
`BaseException`. The final state suite passed 21 cases, all 257 Jellyfin tests
passed on the complete rerun, and all 218 dependency-free policy tests passed.
Python compilation, queue validation and diff checks were clean. Independent
final review of exact `560c756` was CLEAR with no open P1/P2 finding.

This remains diagnostic code and synthetic evidence. Native run 10 is required
to observe one of the new state-read results. It cannot make Engine or
installation available; `installAvailable` remains false.
