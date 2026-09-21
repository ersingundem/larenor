# Required CI aggregate cancellation contract

Superseding a pull-request revision cancels its test and native matrix jobs.
The required aggregate jobs deliberately use `always()` so actual failed or
skipped dependencies cannot silently satisfy branch protection. Before this
change, those same jobs reported `FAILED` on the canceled old revision and
generated misleading failure notifications. GitHub documents that `always()`
continues on cancellation and that a skipped required job reports success;
simply replacing it with `!cancelled()` would weaken the current-head gate.

This change has exactly three acceptance criteria:

1. `server-test`, `analyze-test`, and the five named native acceptance checks
   keep their required names and graph. Success and explicitly reused native
   evidence pass. A real shard failure, unexpected skip, unknown result, or
   malformed native scope still fails, even if the PR head later changes.
2. A canceled dependency is accepted only when a read-only GitHub PR lookup
   proves the live PR head differs from the exact event head. Cancellation on
   the current head, API timeout/permission failure, malformed event/response,
   and manual runs fail closed. The lookup runs only for cancellation, with
   bounded input and a five-second deadline. No token or PR body is logged.
3. Only the two reusable aggregate caller jobs and five native aggregate jobs
   gain `pull-requests: read`; all retain `contents: read`, same-revision
   checkout and pinned actions. Workflow policy and negative tests protect
   that boundary.

Evidence: 376 tool tests passed (four pre-existing skips), `actionlint` on all
eight changed workflows passed, and Ruff, security policy, queue validation,
progress trailers, secret scan and diff hygiene passed. Existing failed runs
remain historical; the change applies to new workflow revisions. A truly
canceled current-head required check still blocks merging.

References: [GitHub workflow cancellation](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-cancellation),
[skipped required jobs](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-jobs-with-conditions).
