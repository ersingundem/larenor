import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/server/core_backups/presentation/server_core_backups_screen.dart';
import 'package:larenor/features/server/core_backups/presentation/server_core_backup_file_access.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server_core_backups_test.dart';

final class FixtureCoreBackupFiles extends ServerCoreBackupFileAccess {
  int saves = 0;
  Uint8List? bytes;
  String? filename;

  @override
  Future<Uri?> save(Uint8List bytes, String filename) async {
    saves++;
    this.bytes = Uint8List.fromList(bytes);
    this.filename = filename;
    return Uri.parse('content://larenor-test/$filename');
  }
}

Future<void> reveal(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    320,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  Future<BackupFixture> mount(
    WidgetTester tester, {
    required String language,
    required double width,
    Map<String, dynamic>? response,
    FixtureCoreBackupFiles? files,
  }) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'settings_pin': '1234'});
    final fixture = BackupFixture();
    if (response != null) fixture.response = response;
    await fixture.account.initialize();
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(fixture.account),
          if (files != null)
            serverCoreBackupFileAccessProvider.overrideWithValue(files),
        ],
        child: CupertinoApp(
          locale: Locale(language),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: const ServerCoreBackupsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.account.dispose();
    });
    return fixture;
  }

  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets(
        '$language ${width.toInt()} wide plan is readable at 2x without restore mutation',
        (tester) async {
          final fixture = await mount(tester, language: language, width: width);
          expect(
            find.byKey(const ValueKey('server-backups-refresh')),
            findsOneWidget,
          );
          expect(
            find.text(
              language == 'tr'
                  ? 'Şifreli yedek için hazır'
                  : 'Ready for an encrypted backup',
            ),
            findsOneWidget,
          );
          await tester.drag(find.byType(ListView), const Offset(0, -800));
          await tester.pumpAndSettle();
          expect(
            find.text(language == 'tr' ? 'Aile panosu' : 'Family board'),
            findsOneWidget,
          );
          await reveal(
            tester,
            find.text(
              language == 'tr'
                  ? 'Boş Core kurtarma sınırı'
                  : 'Empty-Core recovery boundary',
            ),
          );
          expect(
            find.text(
              language == 'tr'
                  ? 'Boş Core kurtarma sınırı'
                  : 'Empty-Core recovery boundary',
            ),
            findsOneWidget,
          );
          expect(find.textContaining('restore now'), findsNothing);
          expect(fixture.mutations, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'blocked plan exposes the operation count and remains read-only',
    (tester) async {
      final fixture = await mount(
        tester,
        language: 'en',
        width: 700,
        response: {
          'status': 'blocked',
          'blockers': ['active_plugin_job', 'active_tablet_command'],
          'manifest': null,
        },
      );
      expect(find.text('Backup temporarily blocked'), findsOneWidget);
      expect(find.textContaining('Finish 2 active operation'), findsOneWidget);
      expect(fixture.mutations, isEmpty);
    },
  );

  testWidgets(
    'admin exports encrypted Core bundle through the OS destination without exposing passphrase',
    (tester) async {
      final files = FixtureCoreBackupFiles();
      final fixture = await mount(
        tester,
        language: 'en',
        width: 600,
        files: files,
      );
      await reveal(
        tester,
        find.byKey(const ValueKey('server-backups-passphrase')),
      );
      const secret = 'Synthetic export passphrase 2026';
      await tester.enterText(
        find.byKey(const ValueKey('server-backups-passphrase')),
        secret,
      );
      await tester.enterText(
        find.byKey(const ValueKey('server-backups-confirm-passphrase')),
        secret,
      );

      await reveal(tester, find.byKey(const ValueKey('server-backups-export')));
      await tester.tap(find.byKey(const ValueKey('server-backups-export')));
      await tester.pumpAndSettle();

      expect(files.saves, 1);
      expect(files.bytes, fixture.bundle);
      expect(files.filename, 'larenor-core-backup.larenor-core');
      expect(find.text(secret), findsNothing);
      expect(find.text('Encrypted Core backup saved'), findsOneWidget);
      final request = fixture.adminCalls.singleWhere(
        (call) => call.url.path.endsWith('/admin/backups/export'),
      );
      expect(request.url.query, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Turkish restore preflight names version and schema mismatches without a restore write',
    (tester) async {
      final fixture = await mount(tester, language: 'tr', width: 1200);
      fixture.validationResponse = {
        'compatible': false,
        'reasons': [
          'unsupported_contract_version',
          'core_version_mismatch',
          'database_schema_mismatch',
          'component_schema_mismatch',
        ],
      };
      await reveal(
        tester,
        find.byKey(const ValueKey('server-backups-preflight')),
      );

      await tester.tap(find.byKey(const ValueKey('server-backups-preflight')));
      await tester.pumpAndSettle();

      expect(
        find.text('Yedek sözleşmesi sürümü desteklenmiyor'),
        findsOneWidget,
      );
      expect(find.text('Core sürümü uyumsuz'), findsOneWidget);
      expect(find.text('Veritabanı şeması uyumsuz'), findsOneWidget);
      expect(find.text('Bileşen şeması uyumsuz'), findsOneWidget);
      expect(find.textContaining('geri yüklenmedi'), findsOneWidget);
      expect(
        fixture.adminCalls.where(
          (call) =>
              call.url.path.contains('/restore') &&
              !call.url.path.endsWith('/restore/validate'),
        ),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('disposed route never saves a delayed export', (tester) async {
    final files = FixtureCoreBackupFiles();
    final fixture = await mount(
      tester,
      language: 'en',
      width: 600,
      files: files,
    );
    fixture.exportPending = Completer<http.Response>();
    await reveal(
      tester,
      find.byKey(const ValueKey('server-backups-passphrase')),
    );
    await tester.enterText(
      find.byKey(const ValueKey('server-backups-passphrase')),
      'Synthetic export passphrase 2026',
    );
    await tester.enterText(
      find.byKey(const ValueKey('server-backups-confirm-passphrase')),
      'Synthetic export passphrase 2026',
    );
    await reveal(tester, find.byKey(const ValueKey('server-backups-export')));
    await tester.tap(find.byKey(const ValueKey('server-backups-export')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    fixture.exportPending!.complete(
      http.Response.bytes(
        fixture.bundle,
        200,
        headers: {
          'content-type': 'application/vnd.larenor.core-backup',
          'content-disposition':
              'attachment; filename="larenor-core-backup.larenor-core"',
          'cache-control': 'no-store',
          'x-content-type-options': 'nosniff',
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(files.saves, 0);
  });
}
