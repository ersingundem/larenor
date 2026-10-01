# Security exact historical fingerprints — 2026-10-01

Exact source `36269cf05091156ae960106eaec27810ff35fc78`,
[Security run 36813874099](https://github.com/ersingundem/larenor/actions/runs/36813874099),
failed in `secret-scan`. Its dependency and platform policy jobs passed. The
scanner found fifteen historical false positives: eleven synthetic fixture/test
values, three bounded documentation/evidence expressions, and one production
variable-to-variable `token` argument. Root independently verified that the
production argument is an AST Name rather than a credential literal.

`.gitleaksignore` contains only the fifteen exact
`commit:path:rule:line` fingerprints. There is no wildcard, whole-path, rule,
commit, scanner-failure suppression, or broad allowlist. The scanner's official
[fingerprint ignore mechanism](https://github.com/gitleaks/gitleaks#gitleaksignore)
is used; historical Git objects and the active scanner policy are preserved.

Root validation with Gitleaks 8.30.1:

- Full `--all` Git-history scan with the exact exceptions: **exit 0, zero findings**.
- A fresh disposable Git fixture using the same exception file and a new
  synthetic candidate: **exit 17, one finding**, still blocking.
- Named security scanner/policy regression: **23 passed, 55 subtests passed**.
- `tool/check_security_policy.py`: passed.

Raw findings and logs remain in a private 0700 evidence directory with 0600
files; no token values are included here. Local scan success is not a hosted
Security or broad latest-HEAD acceptance result. A changed-source hosted run
must pass before that CI gate is accepted.
