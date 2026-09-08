# Exact helper base runtime probe

Native run `34240514836`, source
`42bbcf6c784c53a8a38410a48a947293cbb09e93`, failed on both native architectures
with `phase=helper_build code=fixture_command_exit_failed`. The preserved log is
70,185 bytes, SHA-256
`90cb90f0cdd5008e77e02321a1ba98f97a411a168a6f5b188f376aaf422cb8a2`.
The existing bounded stderr classifier did not identify a known signature.
The underlying build cause remains unresolved; neither a Dockerfile change nor
a runtime compatibility fix is inferred from that result.

Before the existing build, the runner now exercises the exact Python base from
its verified, privately staged Dockerfile on the same owned ephemeral daemon:

1. `helper_base_binding` rechecks the committed source and staged hashes and
   accepts only the current single literal, digest-pinned Python `FROM` form.
2. `helper_base_pull` pulls that reference for the selected native platform.
   `helper_base_inspect` checks its immutable image ID, OS, architecture,
   repository digest and absence of declared volumes. Pull output is not
   identity evidence: the CLI may print a normalized reference.
3. `helper_base_create` creates one named probe using the resolved image ID and
   explicit `--pull=never`. It has no network or mounts, a read-only root,
   no added capabilities, no-new-privileges, user `0:0`, 32 PIDs and 64 MiB.
   `helper_base_created` checks its identity, command, mount/security shape and
   created state before anything starts.
4. `helper_base_start` attaches to one Python process that prints a fixed token.
   `helper_base_result` checks the exact token's completed process: same image,
   container, command and restrictions, exited status, integer exit code zero,
   no running/paused/dead/OOM state. Source and staged hashes are checked again
   before the original helper build can proceed.

A failed or uncertain stage stops the flow. No create/start replay, adoption,
per-container deletion, external socket fallback or success receipt occurs.
The existing owner shuts down its whole daemon/process namespace and removes
its own data directory, including the probe. Pull is bounded to 180 seconds and
4 KiB output; inspect to 64 KiB; create output to 128 bytes; attached execution
to 20 seconds and 128 bytes. Other calls retain the 60-second command default.
The existing 20-minute launcher, 22-minute step and 25-minute job bounds remain.
Probe stderr retains the default discard policy; only the existing build uses
private bounded stderr classification. Output remains closed phase/error codes,
never raw exception, command output, paths, URLs, environment or credentials.

A future probe failure identifies the failed pull/inspect/create/start/readback
boundary. A successful probe establishes only this restricted base process;
it does not reproduce the legacy builder's default security profile or prove
its `RUN`, copy step, UID bootstrap, NoCopy, Jellyfin startup/database or restart
behavior. Those later oracles remain mandatory and unchanged. The base pull can
also warm the same pinned image's local cache; no claim is made that subsequent
build timing or failure remains identical.

The relevant Docker CLI implementations are
[pull](https://github.com/docker/cli/blob/v27.5.1/cli/command/image/pull.go),
[create](https://github.com/docker/cli/blob/v27.5.1/cli/command/container/create.go)
and [attached start](https://github.com/docker/cli/blob/v27.5.1/cli/command/container/start.go).
They support using inspect identity instead of normalized pull output, disabling
implicit create-time pulls, and waiting for attached execution before final
state readback. They are not evidence that the failed native run had a specific
Docker or kernel defect.

`92e156c` recorded seven actual runtime RED cases through the real launcher and
consumer with an owned synthetic daemon. `9ce8f91` made all seven pass.
`e65b8e3` contains 38 new cases: per-stage failure/cleanup, wrong identity,
platform, declared mounts, runtime configuration and exit state, malformed
protocol/output, cancellation, source/stage drift during the probe, unsupported
FROM shapes and native arm64 command selection.

All 210 related cases passed, zero skips, 5.81 seconds: 38 new plus 172 prior.
Existing application assertions still allow only one application create/start
and one restart; the new probe is counted separately, never hidden by allowing
arbitrary additional creates. Three old global call-count assertions initially
failed after the expected new pre-build calls; they now require the exact six
probe calls followed by build and still forbid later work after build drift.
Runner plus unchanged launcher coverage is 97.02% including branches:
547/561 statements and 71/76 branches. The existing 215 policy tests passed in
52.310 seconds; security-policy, syntax and diff checks passed. Independent
source/test review of `9ce8f91` with `e65b8e3` was CLEAR; no duplicate
test or Docker execution was part of that review.

Dockerfile, workflow, launcher, helper/probe programs, Server production,
contracts, app code and success receipt format are unchanged. `installAvailable`
remains false. This work ran no Docker, daemon, home operation, GitHub query,
download, dispatch, push or full Core suite. Real native characterization is
still pending a separately authorized exact-source CI run.

Private evidence uses `/private/tmp/larenor-jellyfin-base-`; the original failure
remains `/private/tmp/larenor-42bbcf6-native-storage.log` and earlier diagnostic
receipts remain historical records.
