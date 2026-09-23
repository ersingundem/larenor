# S08.8 media cache contract strictness

Date: 23 September 2026

This slice closes three independently observed fail-open parsing gaps in the
central media caches. It does not retire the remaining Direct media clients or
close S08.8, so queue progress remains **26/125** and selected-feature progress
remains **0/63**.

## Accepted behavior

1. A Core catalog page accepts only the exact integer schema version `1`.
   Floating numeric aliases fail before any catalog result can be published.
2. The central music selection cache accepts only exact positive bounded
   integer schema, installation and Core revisions. Its existing exact
   Core/home/account tuple, provider/receiver identity, 30-day TTL and 8 KiB
   quota remain unchanged.
3. The retained music cache now carries a typed
   `music_retained_overview` resource envelope at contract version `1`. The
   envelope binds every installation revision, bootstrap revision and schema,
   Home Assistant/Jellyfin service identity and revision, and provider identity
   and revision to the parsed overview. Schema and resource versions require
   exact integers; the existing tuple, five-minute TTL, 64 KiB quota and
   compare-and-clear lifecycle ownership remain intact.

## TDD evidence

- RED `4fb15d478f0f69d17a810309edc4755afc4403a3` added catalog,
  selection and retained-cache regressions. The focused run failed on five
  expected boundaries: floating catalog schema, floating selection revisions,
  the absent retained resource envelope, floating retained cache schema and
  floating retained overview schema.
- GREEN `14c512c3779b6df9f9553c872c58d39a68f57ffe` made the schema
  checks exact and added strict retained resource serialization and matching.

## Verification

The grouped catalog, cache integration, real-loopback replacement, music
manager, selection and retained-status package passed **94/94** tests. It
includes logout, route retirement, delayed replacement ownership, another
Core/home/account tuple, TTL, UTF-8 quota, EN/TR tablet rendering and the
same-URL Core replacement journey. Targeted Flutter analysis over the eight
changed production and test files reports no issues.

Final exact-head gates also run queue validation, progress-trailer validation,
security policy, formatting and `git diff --check` before the PR is opened.

## Remaining S08.8 boundary

The default media hub and navigation still need the separate Direct Jellyfin
and Home Assistant Music Assistant retirement work. Central browse parity and
one complete catalog-to-playback plus music queue real-loopback journey also
remain open. These gates keep S08.8 pending and both counters unchanged.
