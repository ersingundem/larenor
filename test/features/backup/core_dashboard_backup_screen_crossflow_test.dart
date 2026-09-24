import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/configuration_scope.dart';
import 'package:larenor/core/home_data_scope.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/core/window/window_policy_models.dart';
import 'package:larenor/core/window/window_policy_providers.dart';
import 'package:larenor/features/backup/data/backup_codec.dart';
import 'package:larenor/features/backup/data/backup_repository.dart';
import 'package:larenor/features/backup/data/backup_restore_access.dart';
import 'package:larenor/features/backup/data/backup_restore_access_provider.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';
import 'package:larenor/features/backup/presentation/backup_file_access.dart';
import 'package:larenor/features/backup/presentation/backup_screen.dart';
import 'package:larenor/features/settings/data/pin_lock_store.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import 'backup_test_storage.dart';

final _scopeA = HomeDataScope.fromJson({
  'coreId': 'a' * 32,
  'homeId': 'b' * 32,
  'userId': '1' * 32,
});
final _scopeB = HomeDataScope.fromJson({
  'coreId': 'c' * 32,
  'homeId': 'd' * 32,
  'userId': '2' * 32,
});

String _record(HomeDataScope scope, String room) => jsonEncode({
  'version': 1,
  'scope': scope.toJson(),
  'revision': 4,
  'layout': {
    'schemaVersion': 2,
    'rooms': [
      {'id': room, 'name': room, 'entityIds': <String>[]},
    ],
    'tiles': <Object>[],
    'favoriteEntityIds': <String>[],
    'hiddenEntityIds': <String>[],
  },
});

class _Codec extends BackupCodec {
  @override
  Future<BackupSnapshot> decrypt(Uint8List bytes, String passphrase) async =>
      BackupSnapshot.fromJson({
        'version': 3,
        'createdAt': '2026-09-24T00:00:00Z',
        'groups': {
          'privacy': {
            'version': 1,
            'entityIds': <String>[],
            'reviewRequired': true,
          },
          'dashboard': {
            'schemaVersion': 2,
            'rooms': [
              {
                'id': 'restored-a',
                'name': 'Restored A',
                'entityIds': <String>[],
              },
            ],
            'tiles': <Object>[],
            'favoriteEntityIds': <String>[],
            'hiddenEntityIds': <String>[],
          },
          'dashboardOwner': {
            'source': HomeSource.verifiedCore.name,
            'scope': _scopeA.toJson(),
          },
        },
      });
}

class _Files extends BackupFileAccess {
  @override
  Future<Uint8List?> pick() async => Uint8List.fromList([1, 2, 3]);
}

class _Pin extends PinLockStore {
  @override
  Future<String?> read() async => null;
}

class _Access implements BackupRestoreAccess {
  @override
  HomeSource get source => HomeSource.verifiedCore;

  @override
  Map<String, dynamic> get ownership => {
    'source': source.name,
    'scope': _scopeB.toJson(),
  };

  @override
  DateTime get validUntil => DateTime.utc(2030);

  @override
  void checkLive() {}

  @override
  Future<void> checkDurable() async {}
}

void main() {
  testWidgets(
    'foreign Core backup cannot publish a preview or change either scoped layout',
    (tester) async {
      final storage = MemoryBackupStorage(
        preferences: {
          _scopeA.storageKey: _record(_scopeA, 'A room'),
          _scopeB.storageKey: _record(_scopeB, 'B room'),
        },
      );
      final beforeA = storage.preferences[_scopeA.storageKey];
      final beforeB = storage.preferences[_scopeB.storageKey];
      FlutterSecureStorage.setMockInitialValues({});
      await tester.pumpWidget(
        ConfigurationScope(
          child: ProviderScope(
            overrides: [
              backupRepositoryProvider.overrideWithValue(
                BackupRepository(storage: storage),
              ),
              backupCodecProvider.overrideWithValue(_Codec()),
              backupFileAccessProvider.overrideWithValue(_Files()),
              pinLockStoreProvider.overrideWith((_) => _Pin()),
              backupRestoreAccessFactoryProvider.overrideWithValue(
                ({required expectedPin, required isCurrent}) async => _Access(),
              ),
              windowPolicySnapshotProvider.overrideWith(
                (_) => Stream.value(const WindowPolicySnapshot()),
              ),
            ],
            child: CupertinoApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const BackupScreen(freshInstall: true),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('backup-pick')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('backup-restore-passphrase')),
        'correct backup phrase',
      );
      await tester.tap(find.byKey(const ValueKey('backup-decrypt')));
      await tester.pumpAndSettle();

      expect(find.text('Restore preview'), findsNothing);
      expect(
        find.text(
          'This selection contains Direct home data. Switch to Direct home to review it. Core layouts are not part of this backup format.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('backup-apply')), findsNothing);
      expect(storage.preferences[_scopeA.storageKey], beforeA);
      expect(storage.preferences[_scopeB.storageKey], beforeB);
      expect(storage.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
