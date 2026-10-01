# F62 initial-frame subscriber repair — 1 October 2026

The owned FreeRDP shadow fixture had an update-publication race. In pinned
FreeRDP 3.31.1, `shadow_client_context_new` adds the client to the server list
before the peer handshake. `peer->Initialize` can then activate the client and
publish its full-screen refresh. The client update subscriber is created only
after `peer->Initialize` returns. The shadow multi-client publisher marks only
subscribers that exist at publication time; it does not retain an edge for a
later subscriber. The X11 capture loop can therefore publish and clear the
already-rendered static root surface before that subscriber exists.

The source-locked owned fixture now requests the full-screen refresh again
after the update subscriber and its event handle exist, when the client is
already active. The request is still handled by FreeRDP's normal subsystem
message and update path. A failed request terminates the client; it is not
treated as a successful frame. The change is compiled only with
`WITH_LARENOR_F62_OWNED_CHANNELS` and does not alter the packaged Android
client, TLS/NLA policy, framebuffer validation, ACK lifecycle, DISP witness,
clipboard witness, or disabled-channel lifetime.

[Run 36805226494](https://github.com/ersingundem/larenor/actions/runs/36805226494)
at exact revision `1d1ccf2e14e5814800417c32cbe45e8e1fceb24c` passed the
owned Linux fixture build and arm64 package lane. Its x86_64 instrumentation
reported the original single test with one failure and no error or skip. The
bounded owned frames identify the wait for an expected 1280x800 frame after
the security callback. `serverResizeRequested` was false. That evidence does
not establish that there were zero callbacks: the helper can acknowledge
intermediate frames of another size before timing out. It also does not by
itself prove that the subscriber race caused that hosted failure.

The race and the lost-edge behavior are established from the pinned source
ordering. A changed-source hosted run must still pass the unchanged strict
one-test, zero-skip gate with rendered pixels, exact initial and resized
dimensions, ACKs, client DISP effect, Unicode clipboard effect, disabled
clipboard zero transfer, and clean terminal handling. Until that run passes,
this is a source repair with local preparation evidence, not an accepted F62
runtime receipt.

## Source and local evidence

- The verified FreeRDP 3.31.1 release archive has SHA-256
  `4a2629026896cb4e26fb8ed2d6ca6aa4ab89ca95528dfbae2550c2f6bc866991`.
- The updated owned-fixture patch has SHA-256
  `b94f68932544e793f1a413c87ba6cbb84db20c9e316dbcce878decd19a110baa`.
- Patched `server/shadow/shadow_client.c` has SHA-256
  `a07adfae3ef11288f05d72fd5c32899522a4b7ab21a6387f3679a3f5c62ac797`.
- Fresh extraction, patch application and `verify_patched_source` passed from
  the exact release archive.
- `python3 -m unittest tool.tests.f62_owned_shadow_channels_test` passed 18
  tests. The focused ordering check binds the refresh to the exact verified
  source and requires subscriber registration before the replay and channel
  event setup after it. This static contract does not replace the hosted frame
  gate.

Primary source references:

- FreeRDP shadow client activation and update subscription:
  <https://github.com/FreeRDP/FreeRDP/blob/3.31.1/server/shadow/shadow_client.c>
- FreeRDP multi-client publication semantics:
  <https://github.com/FreeRDP/FreeRDP/blob/3.31.1/server/shadow/shadow_mcevent.c>
- FreeRDP X11 capture and invalid-region lifecycle:
  <https://github.com/FreeRDP/FreeRDP/blob/3.31.1/server/shadow/X11/x11_shadow.c>

Root independently prepared the exact release archive into a fresh private tree,
verified every patched-source hash, and inspected the actual full thread order:
subscriber → event → activated refresh request → channel event. Root passed
18/18 focused checks; a separate read-only source review found no acceptance
weakening or teardown defect. No Linux runtime or frame acceptance is claimed
by these local checks.
