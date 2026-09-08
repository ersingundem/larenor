# Helper base zero-state diagnostics

Native run 8 (`34263828110`) used exact source
`18b46234498c1a9b380b8258c33a926386f47111`. Both native jobs failed before
producing a success receipt, but the closed observations differed:

- arm64: `phase=helper_base_start code=helper_base_wait_failed`;
- amd64: `phase=helper_base_start code=fixture_command_exit_failed`.

The failed log was downloaded exactly once to
`/private/tmp/larenor-18b4623-native8-failed.log`: 70,190 bytes, SHA-256
`27dbd3a1724475af715faa1e2c4cd5e4d3c5350a2b0cca92aeb91a28611b4a82`.
The result rules out a single proven cross-architecture cause. In particular,
the arm64 wait signature does not establish whether the container process
failed, succeeded, or never started; amd64 still has no matched stderr family.

The existing owned post-failure `.State` read treated two valid, useful states
as generic fallback. Commit `415aa7ba294f3c3bf075a27d0c68c74afa008f40`
adds only these cause-neutral reductions:

| Closed code | Exact bounded state |
| --- | --- |
| `helper_base_process_exited_zero` | Empty `State.Error`, status `exited`, integer exit code zero, and all active/dead/OOM flags false. |
| `helper_base_process_not_started` | Empty `State.Error`, status `created`, integer exit code zero, and all active/dead/OOM flags false. |

Neither code claims that attach, wait, daemon, runtime, kernel, image, or
application behavior caused the Docker CLI failure. A nonempty unknown error
continues to preserve the original closed code. Invalid types, missing fields,
oversized data, read failure, cancellation, OOM, dead, running and nonzero
states retain their earlier handling. The same single start attempt, one
10-second/65,536-byte `.State` inspect, owned socket/container ID, no retry,
whole-daemon cleanup and private-data rules are unchanged.

TDD first produced two real failures: exited-zero and created-zero both returned
the previous generic code. The focused state suite then passed all 15 cases.
One older synthetic start-failure assertion correctly changed because its fake
container already represented an exited-zero process; after updating that
expected closed result, all 251 Jellyfin tests passed. All 215 dependency-free
policy tests passed, and security policy, Python compilation and diff checks
were clean. Independent read-only review of exact `415aa7b` was CLEAR with no
new P1/P2 finding. This is diagnostic code and synthetic evidence. Native run
9 is required to observe either new state, and `installAvailable` remains
false.
