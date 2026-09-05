import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/core/direct_credential_record.dart';
import 'package:larenor/features/auth/data/credentials_store.dart';
import 'package:larenor/features/auth/data/ha_discovery.dart';
import 'package:larenor/features/auth/presentation/connect_screen.dart';
import 'package:larenor/features/backup/data/backup_codec.dart';
import 'package:larenor/features/backup/data/backup_repository.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';
import 'package:larenor/features/backup/presentation/backup_file_access.dart';
import 'package:larenor/features/backup/presentation/backup_screen.dart';
import 'package:larenor/features/settings/data/pin_lock_store.dart';
import 'package:larenor/features/settings/presentation/settings_gate_screen.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'backup_test_storage.dart';

final _snapshot = BackupSnapshot.fromJson({
  'version': 1,
  'createdAt': '2026-09-05T10:00:00Z',
  'groups': {
    'settings': {'appearance': 'dark'},
    'dashboard': {
      'rooms': [
        {
          'id': 'room',
          'name': 'Private room',
          'entityIds': ['light.private'],
        },
      ],
      'tiles': [],
      'favoriteEntityIds': ['light.private'],
      'hiddenEntityIds': [],
    },
    'connections': {
      'ha': {
        'baseUrl': 'http://private-server.test',
        'token': 'fake-token-never-render',
      },
    },
  },
});

class _Repository extends BackupRepository {
  BackupSelection? captured;
  BackupSelection? restored;
  BackupConflictPolicy? conflict;
  int restoreCalls = 0;
  @override
  Future<BackupSnapshot> capture(BackupSelection selection) async {
    captured = selection;
    return _snapshot;
  }

  @override
  Future<BackupPreview> preview(BackupSnapshot snapshot) async => BackupPreview(
    createdAt: DateTime.utc(2026, 9, 5),
    hasSettings: true,
    hasDashboard: true,
    hasConnections: true,
    settingCount: 1,
    roomCount: 1,
    tileCount: 0,
    favoriteCount: 1,
    services: ['ha'],
    existingSettingsCount: 1,
    existingDashboard: true,
    existingServices: ['ha'],
    requiresCertificateReview: false,
  );
  @override
  Future<void> restore(
    BackupSnapshot snapshot,
    BackupSelection selection, {
    BackupConflictPolicy conflictPolicy = BackupConflictPolicy.keepExisting,
  }) async {
    restoreCalls++;
    restored = selection;
    conflict = conflictPolicy;
  }
}

class _Codec extends BackupCodec {
  Completer<BackupSnapshot>? pending;
  BackupSnapshot? snapshot;
  Object? failure;
  int encryptCalls = 0;
  int decryptCalls = 0;
  @override
  Future<Uint8List> encrypt(BackupSnapshot snapshot, String passphrase) async {
    encryptCalls++;
    return Uint8List.fromList([7, 8, 9]);
  }

  @override
  Future<BackupSnapshot> decrypt(Uint8List bytes, String passphrase) async {
    decryptCalls++;
    if (failure != null) throw failure!;
    return pending == null ? snapshot ?? _snapshot : pending!.future;
  }
}

class _Files extends BackupFileAccess {
  Completer<Uint8List?>? pending;
  bool cancel = false;
  Object? failure;
  int picks = 0;
  String? savedName;
  Uint8List? savedBytes;
  @override
  Future<Uint8List?> pick() async {
    picks++;
    if (failure != null) throw failure!;
    if (pending != null) return pending!.future;
    return cancel ? null : Uint8List.fromList([7, 8, 9]);
  }

  @override
  Future<Uri?> save(Uint8List bytes, String filename) async {
    savedName = filename;
    savedBytes = Uint8List.fromList(bytes);
    return cancel ? null : Uri.parse('content://documents/example');
  }
}

class _Pin extends PinLockStore {
  _Pin(this.pin);
  String? pin;
  @override
  Future<String?> read() async => pin;
  @override
  Future<PinAttemptResult> verify(String candidate) async =>
      PinAttemptResult(accepted: candidate == pin);
}

class _NoDiscovery extends HaDiscoveryService {
  @override
  Future<void> start() async {}
}

Future<void> _mount(
  WidgetTester tester, {
  BackupRepository? repository,
  _Codec? codec,
  _Files? files,
  _Pin? pin,
  bool freshInstall = false,
  bool gate = false,
  bool connect = false,
  AppInteractionController? interaction,
  Locale locale = const Locale('en'),
  Size size = const Size(700, 1600),
  double textScale = 1,
}) async {
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        backupRepositoryProvider.overrideWithValue(repository ?? _Repository()),
        backupCodecProvider.overrideWithValue(codec ?? _Codec()),
        backupFileAccessProvider.overrideWithValue(files ?? _Files()),
        pinLockStoreProvider.overrideWithValue(pin ?? _Pin(null)),
        haDiscoveryFactoryProvider.overrideWithValue(_NoDiscovery.new),
        backupRestoreHandlerProvider.overrideWithValue(
          (context, operation, l10n) => operation(),
        ),
      ],
      child: CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: interaction == null
              ? child!
              : AppInteractionScope(controller: interaction, child: child!),
        ),
        home: gate
            ? const SettingsGateScreen()
            : connect
            ? const ConnectScreen()
            : BackupScreen(freshInstall: freshInstall),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pump();
}

Future<void> _importPreview(WidgetTester tester) async {
  await _tap(tester, 'backup-pick');
  await tester.enterText(
    find.byKey(const ValueKey('backup-restore-passphrase')),
    'correct backup phrase',
  );
  await _tap(tester, 'backup-decrypt');
  await tester.pump();
}

void _background(WidgetTester tester) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
}

void _resume(WidgetTester tester) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

void main() {
  for (final language in ['en', 'tr']) {
    for (final operation in ['export', 'preview']) {
      testWidgets(
        'pending HA $operation gives $language recovery guidance at tablet 2x',
        (tester) async {
          const pendingKey = CredentialsStore.pendingMutationKey;
          final storage = MemoryBackupStorage(
            secrets: {
              'ha_base_url': 'https://synthetic.example.test',
              'ha_token': 'synthetic-private-token',
              pendingKey: '1',
            },
          );
          final codec = _Codec();
          final files = _Files();
          await _mount(
            tester,
            repository: BackupRepository(storage: storage),
            codec: codec,
            files: files,
            freshInstall: operation != 'export',
            locale: Locale(language),
            size: Size(language == 'tr' ? 600 : 1200, 1000),
            textScale: 2,
          );
          if (operation == 'export') {
            await _tap(tester, 'backup-connections');
            await tester.enterText(
              find.byKey(const ValueKey('backup-passphrase')),
              'correct backup phrase',
            );
            await tester.enterText(
              find.byKey(const ValueKey('backup-confirm-passphrase')),
              'correct backup phrase',
            );
            await _tap(tester, 'backup-export');
          } else {
            await _importPreview(tester);
          }
          await tester.pumpAndSettle();
          final message = find.text(
            language == 'en'
                ? 'Reconnect Home Assistant, then try backing up or restoring connections again.'
                : 'Home Assistant bağlantısını yeniden kurun, ardından bağlantıları yedeklemeyi veya geri yüklemeyi tekrar deneyin.',
          );
          expect(message, findsOneWidget);
          await tester.ensureVisible(message);
          expect(
            tester.getRect(message).width,
            lessThanOrEqualTo(language == 'tr' ? 600 : 1200),
          );
          expect(storage.writes, isEmpty);
          expect(storage.secrets[pendingKey], '1');
          expect(codec.encryptCalls, 0);
          expect(files.savedBytes, isNull);
          expect(find.textContaining('synthetic-private'), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
  for (final language in ['en', 'tr']) {
    for (final operation in ['export', 'preview']) {
      testWidgets(
        'pending Direct $operation gives $language recovery guidance at tablet 2x',
        (tester) async {
          final pendingKey = DirectCredentialService.sonarr.pendingMutationKey;
          final storage = MemoryBackupStorage(
            secrets: {
              'sonarr_base_url': 'https://synthetic.example.test',
              'sonarr_api_key': 'synthetic-private-token',
              pendingKey: '1',
            },
          );
          final codec = _Codec()
            ..snapshot = BackupSnapshot.fromJson({
              'version': 1,
              'createdAt': '2026-09-06T00:00:00.000Z',
              'groups': {
                'connections': {
                  'sonarr': {
                    'baseUrl': 'https://incoming.example.test',
                    'apiKey': 'synthetic-incoming',
                  },
                },
              },
            });
          final files = _Files();
          await _mount(
            tester,
            repository: BackupRepository(storage: storage),
            codec: codec,
            files: files,
            freshInstall: operation != 'export',
            locale: Locale(language),
            size: Size(language == 'tr' ? 600 : 1200, 1000),
            textScale: 2,
          );
          if (operation == 'export') {
            await _tap(tester, 'backup-connections');
            await tester.enterText(
              find.byKey(const ValueKey('backup-passphrase')),
              'correct backup phrase',
            );
            await tester.enterText(
              find.byKey(const ValueKey('backup-confirm-passphrase')),
              'correct backup phrase',
            );
            await _tap(tester, 'backup-export');
          } else {
            await _importPreview(tester);
          }
          await tester.pumpAndSettle();
          final message = find.text(
            language == 'en'
                ? 'Complete the unfinished service connection in its settings, then try backing up or restoring connections again.'
                : 'Yarım kalan servis bağlantısını ayarlarından yeniden tamamlayın, ardından bağlantıları yedeklemeyi veya geri yüklemeyi tekrar deneyin.',
          );
          expect(message, findsOneWidget);
          await tester.ensureVisible(message);
          expect(
            tester.getRect(message).width,
            lessThanOrEqualTo(language == 'tr' ? 600 : 1200),
          );
          expect(storage.writes, isEmpty);
          expect(storage.secrets[pendingKey], '1');
          expect(codec.encryptCalls, 0);
          expect(files.savedBytes, isNull);
          expect(find.textContaining('synthetic-private'), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
  testWidgets(
    'fresh-install idle expires decrypted preview and old confirmation performs zero restores',
    (tester) async {
      final scope = AppInteractionController();
      addTearDown(scope.dispose);
      final repository = _Repository();
      await _mount(
        tester,
        freshInstall: true,
        repository: repository,
        interaction: scope,
      );
      await _importPreview(tester);
      expect(find.text('Restore preview'), findsOneWidget);
      await _tap(tester, 'backup-apply');
      // Applying remains pending behind its confirmation spinner.
      await tester.pump(const Duration(milliseconds: 400));
      final old = tester
          .widget<CupertinoDialogAction>(
            find.widgetWithText(
              CupertinoDialogAction,
              'Restore selected content',
            ),
          )
          .onPressed!;
      scope.setActive(false);
      await tester.pump();
      scope.setActive(true);
      await tester.pumpAndSettle();
      old();
      await tester.pumpAndSettle();
      expect(repository.restoreCalls, 0);
      expect(find.text('Restore preview'), findsNothing);
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'decrypt finishing after idle and wake cannot republish plaintext preview',
    (tester) async {
      final scope = AppInteractionController();
      addTearDown(scope.dispose);
      final codec = _Codec()..pending = Completer<BackupSnapshot>();
      final repository = _Repository();
      await _mount(
        tester,
        freshInstall: true,
        repository: repository,
        codec: codec,
        interaction: scope,
      );
      await _tap(tester, 'backup-pick');
      await tester.enterText(
        find.byKey(const ValueKey('backup-restore-passphrase')),
        'correct backup phrase',
      );
      await _tap(tester, 'backup-decrypt');
      scope.setActive(false);
      await tester.pump();
      scope.setActive(true);
      await tester.pump();
      codec.pending!.complete(_snapshot);
      await tester.pumpAndSettle();
      expect(find.text('Restore preview'), findsNothing);
      expect(repository.restoreCalls, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'export excludes credentials by default and saves ciphertext with portable extension',
    (tester) async {
      final repository = _Repository();
      final files = _Files();
      await _mount(tester, repository: repository, files: files);
      expect(
        tester
            .widget<CupertinoSwitch>(
              find.byKey(const ValueKey('backup-connections')),
            )
            .value,
        isFalse,
      );
      await tester.enterText(
        find.byKey(const ValueKey('backup-passphrase')),
        'correct backup phrase',
      );
      await tester.enterText(
        find.byKey(const ValueKey('backup-confirm-passphrase')),
        'correct backup phrase',
      );
      await _tap(tester, 'backup-export');
      expect(repository.captured!.settings, isTrue);
      expect(repository.captured!.dashboard, isTrue);
      expect(repository.captured!.connections, isFalse);
      expect(files.savedName, endsWith('.larenor-vault'));
      expect(files.savedBytes, [7, 8, 9]);
      expect(find.textContaining('Encrypted backup saved'), findsOneWidget);
      expect(
        tester
            .widget<CupertinoTextField>(
              find.byKey(const ValueKey('backup-passphrase')),
            )
            .controller!
            .text,
        isEmpty,
      );
    },
  );

  testWidgets(
    'export rejects short, mismatched and Settings PIN passphrases before capture',
    (tester) async {
      final repository = _Repository();
      await _mount(tester, repository: repository, pin: _Pin('123456789012'));
      await _tap(tester, 'backup-export');
      expect(find.text('Use at least 12 characters.'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('backup-passphrase')),
        '123456789012',
      );
      await _tap(tester, 'backup-export');
      expect(find.text('The passphrases do not match.'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('backup-confirm-passphrase')),
        '123456789012',
      );
      await _tap(tester, 'backup-export');
      expect(
        find.text(
          'Choose a backup passphrase different from your Settings PIN.',
        ),
        findsOneWidget,
      );
      expect(repository.captured, isNull);
    },
  );

  testWidgets(
    'restore previews counts and conflicts without rendering secrets or applying data',
    (tester) async {
      final repository = _Repository();
      await _mount(tester, freshInstall: true, repository: repository);
      await _importPreview(tester);
      expect(find.text('Restore preview'), findsOneWidget);
      expect(find.textContaining('1 preferences · 1 rooms'), findsOneWidget);
      expect(find.textContaining('private-server'), findsNothing);
      expect(find.textContaining('fake-token'), findsNothing);
      expect(find.textContaining('Private room'), findsNothing);
      expect(repository.restoreCalls, 0);
      expect(
        tester
            .widget<CupertinoSwitch>(
              find.byKey(const ValueKey('backup-connections')),
            )
            .value,
        isFalse,
      );
      await tester.ensureVisible(find.text('Replace selected'));
      await tester.tap(find.text('Replace selected'));
      await tester.pumpAndSettle();
      await _tap(tester, 'backup-apply');
      expect(repository.restoreCalls, 0);
      await tester.tap(
        find.widgetWithText(CupertinoDialogAction, 'Restore selected content'),
      );
      await tester.pump();
      expect(repository.restoreCalls, 1);
      expect(repository.conflict, BackupConflictPolicy.replaceSelected);
      expect(repository.restored!.connections, isFalse);
    },
  );

  testWidgets(
    'wrong password is sanitized; cancellation and picker errors do not change settings',
    (tester) async {
      final repository = _Repository();
      final codec = _Codec()..failure = StateError('fake-token-do-not-show');
      final files = _Files()..cancel = true;
      await _mount(
        tester,
        freshInstall: true,
        repository: repository,
        codec: codec,
        files: files,
      );
      await _tap(tester, 'backup-pick');
      expect(find.text('Cancelled. No settings were changed.'), findsOneWidget);
      files.cancel = false;
      await _importPreview(tester);
      expect(
        find.textContaining('Could not unlock this backup'),
        findsOneWidget,
      );
      expect(find.textContaining('fake-token'), findsNothing);
      expect(find.text('Restore preview'), findsNothing);
      files.failure = const BackupFileTooLarge();
      await _tap(tester, 'backup-pick');
      expect(find.text('This file is too large to restore.'), findsOneWidget);
      expect(repository.restoreCalls, 0);
    },
  );

  testWidgets(
    'busy decrypt ignores duplicate taps and late completion after background',
    (tester) async {
      final codec = _Codec()..pending = Completer<BackupSnapshot>();
      await _mount(tester, freshInstall: true, codec: codec);
      await _importPreview(tester);
      await _tap(tester, 'backup-decrypt');
      expect(codec.decryptCalls, 1);
      _background(tester);
      await tester.pump();
      expect(
        find.text('Unlock Settings to continue restoring.'),
        findsOneWidget,
      );
      codec.pending!.complete(_snapshot);
      await tester.pump();
      _resume(tester);
      await tester.pump();
      expect(find.text('Restore preview'), findsNothing);
      expect(
        tester
            .widget<CupertinoTextField>(
              find.byKey(const ValueKey('backup-restore-passphrase')),
            )
            .controller!
            .text,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'fresh-install restore fails closed when a Settings PIN already exists',
    (tester) async {
      final files = _Files();
      await _mount(tester, freshInstall: true, files: files, pin: _Pin('1234'));
      expect(
        find.text('Unlock Settings to continue restoring.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('backup-pick')), findsNothing);
      expect(files.picks, 0);
    },
  );

  testWidgets(
    'Connect only exposes restore when no existing Settings PIN exists',
    (tester) async {
      await _mount(tester, connect: true, pin: _Pin('1234'));
      await tester.pump(const Duration(seconds: 6));
      expect(
        find.byKey(const ValueKey('connect-restore-backup')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
      await _mount(tester, connect: true);
      await tester.pump(const Duration(seconds: 6));
      expect(
        find.byKey(const ValueKey('connect-restore-backup')),
        findsOneWidget,
      );
      await _tap(tester, 'connect-restore-backup');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('backup-pick')), findsOneWidget);
      expect(find.byKey(const ValueKey('backup-export')), findsNothing);
    },
  );

  testWidgets(
    'native picker retains only encrypted selection and requires fresh PIN after relock',
    (tester) async {
      final files = _Files()..pending = Completer<Uint8List?>();
      await _mount(tester, gate: true, files: files, pin: _Pin('1234'));
      await tester.enterText(find.byType(CupertinoTextField), '1234');
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Backup & Restore'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore from backup'));
      await tester.pumpAndSettle();
      await _tap(tester, 'backup-pick');
      _background(tester);
      await tester.pump();
      expect(find.byKey(const ValueKey('backup-decrypt')), findsNothing);
      _resume(tester);
      files.pending!.complete(Uint8List.fromList([7, 8, 9]));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('backup-reauth-pin')), findsOneWidget);
      expect(find.byKey(const ValueKey('backup-decrypt')), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('backup-reauth-pin')),
        '0000',
      );
      await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Unlock'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('backup-reauth-pin')), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('backup-reauth-pin')),
        '1234',
      );
      await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Unlock'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('backup-restore-passphrase')),
        findsOneWidget,
      );
      expect(find.text('Restore preview'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'picker cancellation after background releases the bridge and restores the locked gate',
    (tester) async {
      final files = _Files()..pending = Completer<Uint8List?>();
      await _mount(tester, gate: true, files: files, pin: _Pin('1234'));
      await tester.enterText(find.byType(CupertinoTextField), '1234');
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Backup & Restore'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore from backup'));
      await tester.pumpAndSettle();
      await _tap(tester, 'backup-pick');
      _background(tester);
      _resume(tester);
      files.pending!.complete(null);
      await tester.pumpAndSettle();
      expect(find.text('Unlock'), findsOneWidget);
      expect(find.byType(BackupScreen), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
