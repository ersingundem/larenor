import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:larenor/features/home_scope/data/core_layout_archive_codec.dart';

import 'core_layout_archive_ui_fixture.dart';
import 'core_layout_archive_screen_test.dart'
    show archive, scope, passphrase, cryptoWait, importArchive;

class _FalseWrite extends InMemorySharedPreferencesStore {
  _FalseWrite(super.data, this.commit) : super.withData();
  final bool commit;
  int writes = 0;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (key != 'flutter.${scope.storageKey}') {
      return super.setValue(type, key, value);
    }
    writes++;
    if (commit) await super.setValue(type, key, value);
    return false;
  }
}

void main() {
  late Uint8List encrypted;
  setUpAll(() async {
    encrypted = await const CoreLayoutArchiveCodec().encrypt(
      archive(),
      passphrase,
    );
  });
  testWidgets(
    'OS save failure is visible after encrypted dispatch and passwords are cleared',
    (tester) async {
      final h = ArchiveHarness();
      await h.mount(tester);
      await h.open(tester);
      h.files.onSave = () async =>
          throw StateError('private synthetic OS path');
      await tester.enterText(
        find.byKey(const ValueKey('core-layout-archive-password')),
        passphrase,
      );
      await tester.enterText(
        find.byKey(const ValueKey('core-layout-archive-repeat')),
        passphrase,
      );
      await archivePress(tester, 'core-layout-archive-export');
      await cryptoWait(
        tester,
        find.byKey(const ValueKey('core-layout-archive-message')),
      );
      expect(find.textContaining('private synthetic'), findsNothing);
      expect(find.textContaining('could not be completed'), findsOneWidget);
      expect(h.files.saves, 1);
      for (final key in [
        'core-layout-archive-password',
        'core-layout-archive-repeat',
      ]) {
        expect(
          tester
              .widget<CupertinoTextField>(find.byKey(ValueKey(key)))
              .controller!
              .text,
          isEmpty,
        );
      }
    },
  );
  testWidgets(
    'OS pick failure shows static error and permits a fresh explicit picker',
    (tester) async {
      final h = ArchiveHarness();
      await h.mount(tester);
      await h.open(tester);
      h.files.onPick = () async =>
          throw StateError('private synthetic OS path');
      await archivePress(tester, 'core-layout-archive-pick');
      expect(
        find.byKey(const ValueKey('core-layout-archive-message')),
        findsOneWidget,
      );
      expect(find.textContaining('private synthetic'), findsNothing);
      h.files.onPick = null;
      await archivePress(tester, 'core-layout-archive-pick');
      expect(h.files.picks, 2);
    },
  );
  for (final commit in [false, true]) {
    testWidgets(
      'uncertain platform ACK commit=$commit never shows success or retries and explicit read is honest',
      (tester) async {
        final h = ArchiveHarness();
        await h.mount(tester);
        await h.open(tester);
        await importArchive(tester, h, encrypted);
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        final disk = _FalseWrite({
          for (final key in prefs.getKeys()) 'flutter.$key': prefs.get(key)!,
        }, commit);
        SharedPreferencesStorePlatform.instance = disk;
        await archivePress(tester, 'core-layout-archive-replace');
        final held = tester
            .widget<CupertinoDialogAction>(
              find.byKey(const ValueKey('core-layout-archive-confirm')),
            )
            .onPressed!;
        held();
        await flush(tester);
        held();
        await flush(tester);
        expect(disk.writes, 1);
        expect(find.text('Room layout replaced and verified.'), findsNothing);
        expect(
          find.textContaining('save could not be confirmed'),
          findsOneWidget,
        );
        await archivePress(tester, 'core-layout-archive-refresh');
        expect(disk.writes, 1);
        expect(find.text('Saved room'), commit ? findsOneWidget : findsNothing);
        expect((await h.repository.readSnapshot()).revision, commit ? 1 : 0);
      },
    );
  }
}
