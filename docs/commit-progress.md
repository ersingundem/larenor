# Commit progress trailers

Larenor's durable queue records accepted work separately from work that is in
progress or waiting for CI. New development commits can expose both accepted
measures with the repository wrapper:

```sh
python3 tool/commit_with_progress.py -m 'feat: add the next accepted slice'
```

The command commits the currently staged changes and appends two standard Git
trailers:

```text
Larenor-Queue-Progress: 14/125 (11.2%)
Larenor-Feature-Progress: 0/63 (0.0%)
```

Values always come from the validated `docs/execution-queue.json`. Queue progress
counts only task nodes whose status is `done`. Feature progress counts only
selected `F01`–`F63` tasks whose status is `done`; `in_progress` and `awaiting_ci`
do not increase either percentage. The wrapper does not edit the queue, accept a
task, amend a commit, or rewrite history.

Use repeated `-m` arguments for message paragraphs. The wrapper passes the final
message to Git through standard input with `shell=False`, so shell metacharacters
stay literal. It rejects empty messages, NUL bytes, and caller-supplied
`Larenor-Queue-Progress` or `Larenor-Feature-Progress` lines so the generated
trailers cannot be forged or duplicated.

Review the exact commit message without changing Git state:

```sh
python3 tool/commit_with_progress.py --dry-run -m 'feat: describe the slice'
```

Run the focused regression suite after changing this workflow:

```sh
python3 -m unittest tool.tests.commit_with_progress_test -v
```

Pull requests also run `tool/check_commit_progress.py` against every commit in
the proposed range. The gate requires one correctly calculated queue trailer
and one feature trailer per commit, rejects decreasing counters, and requires
the pull request head to match the validated queue. Direct commits and commits
from parallel branches therefore follow the same visible rule. Its GitHub
Actions summary also lists every short commit ID with both percentages, so the
progress attached to each commit is visible without opening commit messages.
