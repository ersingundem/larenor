# S08.8 scoped music manager cache TDD evidence

23 September 2026. This slice persists one central Core music readback. It does
not close S08.8 or change either progress counter.

## Acceptance boundary

- Only the authenticated `ServerMusicManager` readback is persisted. The
  record is bound to the exact Core, home, account, installation and
  installation/Core/manager revisions.
- The record has exact schema version 1, a five-minute TTL and a 256 KiB UTF-8
  quota. Unknown fields, corrupt JSON, incompatible schema or revision,
  future/expired timestamps and oversized input fail closed.
- A current retained-installation read must establish live authority before a
  cached manager can appear. A restarted controller may expose that manager
  while the live manager read is retried, but marks it unverified and
  unreachable; commands still require fresh verification.
- Access tokens, passwords and service credentials are never serialized. An
  account, home, Core or resource change cannot read the prior snapshot.

## RED

Commit `a6bd5545f5edf7ac8fe62189e3bf84d38d0df19f` added compile-time failing
tests for persistent scoped storage and restart fallback. The cache contract,
backend and controller injection did not yet exist.

## GREEN

Commit `72b9083b291ffd9c6577b6324e99d190f8b354ec` added the schema, strict model
serialization and controller read/write boundary. Commit
`173d5257ea1b67546e89435b151118e4b3dbc824` isolated SharedPreferences state in
the existing widget matrix. Verification completed with:

```text
flutter test \
  test/features/server/server_music_manager_cache_test.dart \
  test/features/server/server_music_manager_controller_test.dart \
  test/features/server/server_music_manager_models_test.dart \
  test/features/server/server_music_manager_screen_test.dart \
  test/features/server/server_music_retained_controller_test.dart \
  test/features/server/server_music_retained_screen_test.dart \
  test/features/server/server_music_retained_status_test.dart

38 tests passed
```

Targeted `flutter analyze` reported no issues for the three changed production
files and two changed tests. The three cache tests cover the real
SharedPreferences restart path, the full tuple/resource/revision/schema/TTL/
quota matrix, and controller restart fallback. Focused cache-module line
coverage is 100/113, or 88.5%. The existing EN/TR, 600/1200, 2x text,
keyboard, semantics and lifecycle matrix remains green.

## Remaining S08.8 work

The wider direct media surfaces and their persistent records still need an
explicit Core migration, including Jellyfin browsing/playback preferences,
movie-night records and the remaining provider/player mappings. Legacy
provider/player migration still needs a user preview and explicit approval.
The full route replacement, authorization-loss and same-URL Core replacement
need integrated Client-to-Core and Android evidence, followed by independent
review and exact-head CI. Queue progress stays 25/125 and selected-feature
progress stays 0/63 until the whole acceptance item closes.
