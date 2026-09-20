# B5.1 device and media tablet acceptance — 2026-09-21

This slice covers Remote Playback, Jellyfin item detail and Playback Power on
the shared tablet settings surface. It was rebased onto `origin/main`
`02d0a6c4`; the post-rebase review retained only behavior absent from main.

## Accepted software criteria

1. **Tablet accessibility and layout.** English and Turkish layouts at 600 and
   1200 logical pixels render at 200% text without overflow. Section headings
   are headings rather than buttons; every action has a minimum 48 dp semantic
   target and remains reachable with keyboard Enter and TalkBack semantics.
2. **Truthful device and media state.** Remote discovery, Jellyfin reads and
   native power reads present loading, empty and failure separately. Remote
   Playback uses the shared connection-evidence model so a saved connection,
   a verified discovery read and an observed device result are not promoted
   into one another. A retained successful timestamp remains explicitly a last
   successful read during failure. An accepted playback request remains
   distinct from observed playback, and an uncertain result never becomes a
   success or triggers an automatic retry.
3. **Exact interaction authority.** Media account replacement, unresolved
   configuration, item replacement, controller or native bridge replacement,
   route coverage, window-idle epoch, offstage visibility and app lifecycle
   changes retire captured callbacks and pending confirmations. A late read or
   callback cannot publish into a new Core/home/account session, navigate from
   a hidden route or issue a media/native command. Playback Power is local-only
   and does not claim Core/home/account authority; it remains bound to the
   current platform bridge, route and interaction epoch.

## Automated evidence

- `flutter test test/features/media/casting/remote_playback_ui_test.dart test/features/media/jellyfin/jellyfin_browse_tablet_contract_test.dart test/features/media/local_audio/playback_power_tablet_accessibility_test.dart test/features/media/local_audio/local_audio_ui_test.dart`
- `flutter analyze` over the three production surfaces and four focused test
  files.
- `python3 tool/check_security_policy.py`
- `python3 tool/execution_queue.py validate`
- `gitleaks dir . --redact --no-banner --log-level error`
- `git diff --check` and a clean `git merge-tree --write-tree origin/main HEAD`.

Queue progress remains **17/125** and feature progress remains **0/63**.
Physical Huawei/DeX/TalkBack acceptance and the final app-wide visual review
remain separate manual gates.
