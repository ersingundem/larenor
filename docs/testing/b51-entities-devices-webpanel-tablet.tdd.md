# B5.1 entities, devices and web-panel tablet evidence

This open B5.1 slice aligns three real Client surfaces with the shared
`ServiceRootScaffold`, `SettingsSection` and `SettingsActionTile` language. It
is based on main `bae12c01dd3eb3e9d3a618623fab84f0e8878ef0`. It does not close
B5.1 or claim physical Huawei, DeX or TalkBack acceptance.

## Acceptance

1. Home Assistant entity rows expose separate named open and enabled controls.
   Enter opens the real registry editor without toggling the entity, and both
   controls keep an effective target of at least 48 dp. A retained row callback
   cannot open or mutate an entity removed or replaced by current registry
   authority.
2. Keenetic search, filtering, refresh and device rows use the same tablet
   hierarchy. Enter opens the real device detail view, while the existing
   session-generation guard still rejects retained refresh callbacks, and a
   retained row cannot open a device removed by the latest provider snapshot.
3. Web-panel settings keep their bounded tablet layout and existing draft
   policy. URL, title and allowed-origin fields have localized TalkBack labels
   and 48 dp targets; keyboard Save returns the same validated `TileConfig`.
   The zoom switch is a named 60 by 48 dp toggle with Enter/Space activation
   and the same stale interaction guard as Save.

The widget matrix covers English and Turkish at 600 and 1200 logical pixels
with 200% text. Synthetic providers exercise the real routes and actions; no
Home Assistant, Keenetic router, website or other home service is contacted.

## Verification

```text
flutter test \
  test/features/admin/entities_tablet_accessibility_test.dart \
  test/features/keenetic/keenetic_devices_tablet_accessibility_test.dart \
  test/features/keenetic/keenetic_screens_test.dart \
  test/features/keenetic/keenetic_operational_boundary_test.dart \
  test/features/keenetic/keenetic_direct_recovery_test.dart \
  test/features/web_panel/web_panel_settings_tablet_accessibility_test.dart \
  test/features/web_panel/web_panel_settings_test.dart

flutter analyze \
  lib/features/admin/presentation/entities_screen.dart \
  lib/features/keenetic/presentation/keenetic_devices_screen.dart \
  lib/features/web_panel/presentation/web_panel_settings_screen.dart \
  test/features/admin/entities_tablet_accessibility_test.dart \
  test/features/keenetic/keenetic_devices_tablet_accessibility_test.dart \
  test/features/keenetic/keenetic_operational_boundary_test.dart \
  test/features/web_panel/web_panel_settings_tablet_accessibility_test.dart
```

The final focused matrix passes **104/104** with no analyzer issues. Exact PR CI
and a physical-device visual/accessibility pass remain separate acceptance
gates.
