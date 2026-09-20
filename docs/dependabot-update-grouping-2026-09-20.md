# Dependabot update grouping

Larenor's version-update maintenance is grouped into one weekly pull request
covering Dart/Flutter packages, Android Gradle dependencies and GitHub Actions.
The group runs on Monday at 03:00 Europe/Istanbul and carries the
`dependencies` label.

This prevents a single weekly scan from opening several independent pull
requests that each reserve the full protected CI matrix. Security alerts and
their remediation remain governed by GitHub's separate security-update flow.
Existing Dependabot pull requests are not rewritten by this configuration;
the grouping applies to later version-update scans.

## Acceptance

1. All three configured ecosystems use the same `weekly-maintenance` group.
2. The weekly schedule and timezone are declared once at group scope.
3. A repository test rejects missing ecosystems, duplicate schedules and
   removal of the stable dependency label.
