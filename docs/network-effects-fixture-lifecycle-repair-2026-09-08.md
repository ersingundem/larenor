# Network create fixture lifecycle repair

Server CI run `34250029666`, source
`25d438aed00b44cf10322a500a4dbb001c920dfd`, reported one failure and 3,759
passing tests. The failing strict-framing case declared Content-Length 100 but
sent only `{}`. Its first failure was `network_create_unavailable` instead of
the required `network_create_protocol`. Teardown then reported a stored socket
`TimeoutError`; the fixture thread had already stopped. The preserved log does
not identify which receive/send raised it and does not prove a leaked socket or
a specifically delayed second POST.

The single downloaded log remains
`/private/tmp/larenor-25d438a-server-ci-failed.log`, 65,925 bytes, SHA-256
`5298d0f0186ca11ea7db36f21cfcf4a7094508ad56ccb5cedc2a80c36f3dfa93`.
No GitHub query, second download, rerun or dispatch was used in this repair.

The synthetic `create_server` fixture had its own two-second accepted-socket
inactivity timer. That timer could close a peer while the transport under test
was still entitled to send/read, replacing its intended framing result with an
availability failure. Simply ignoring that timeout or increasing it would hide
the competing lifecycle owner. The fixture now registers its accepted peer under
a lock, checks the stop event under that same lock, and uses blocking socket I/O.
At owner teardown it sets stop and shuts down only its currently registered
socket under the lock. The worker keeps final `close()` ownership. An accept
returning after stop closes before entering the request reader.

The production transport keeps all of its original deadlines. Fixture shutdown
wakes its blocking receive/send without waiting for a second independent timer.
The listener's 0.1-second accept polling and three-second thread join are
unchanged. Independent callback failures remain recorded, and callbacks that
block outside socket I/O still fail the unchanged join assertion. This change
does not introduce sleeps, operation retries, larger timeout budgets or relaxed
framing acceptance.

Runtime RED `2afe285` used real temporary Unix sockets and retained clients:
partial header, partial body, next-request wait, and accept returning after owner
stop. All four failed against the old fixture. Fixture GREEN `e066f64` passed
those four plus all six original strict-framing parameters. Test-only checkpoint
`d9392fb` makes the read-phase barriers precise and adds a real callback-failure
oracle. It accepts only EOF or `ConnectionResetError` as peer disconnection;
timeout and other errors still fail. A repeat against the old fixture produced
the same four RED failures plus one passing callback test; the new fixture
passed all five. Event barriers coordinate ordering; no timing sleep is used.

Final verification on `d9392fb`:

- 785 related tests passed, five Linux-only cases skipped on macOS, 62.88 seconds.
  The files cover lifecycle, network effects/preparation/transport/resources,
  resource journal, shared HTTP, image resources and image preparation.
- Four concurrent processes across five batches completed all 20 runs: 220
  successful focused executions of the five lifecycle and six framing cases.
  No failed run was retried. Earlier pre-refinement evidence separately records
  200 successful executions and 784 related passes; these are not extra unique
  test cases or native Linux acceptance.
- Modified `create_server`: 74/75 executable lines and 19/20 branches covered.
  The unchanged network-effect adapter was 74/74 lines and 4/4 branches covered.
- AST comparison confirms every existing test body/parameter and the nested
  bounded request reader are unchanged. Header 8,192/body 4,096 byte limits,
  strict incomplete-response rejection, exact request counts and second-request
  exclusion remain. Syntax, static security-policy and diff checks passed.

Independent source review of `e066f64` was CLEAR. No Server production, workflow,
Client, contract or Android source changed. Work was isolated from main on
`codex/network-effects-ci-fix`, based on
`c141ac9ea2d50a48c7f8a7622c254b08ea0c316e`. Private evidence uses
`/private/tmp/larenor-network-effects-`.

This is a fixture synchronization repair with deterministic local regression
proof, not proof of the exact CI scheduling interleaving. Real Linux CI remains
a separate publication gate. No full Core suite, real Engine/Docker, home
network operation, installation or push was performed.
