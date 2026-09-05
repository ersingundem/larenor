import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/features/backup/data/backup_repository.dart';
import 'package:larenor/features/backup/presentation/backup_screen.dart';
import 'package:larenor/features/client_updates/data/client_release_repository.dart';
import 'package:larenor/features/client_updates/presentation/client_updates_screen.dart';
import 'package:larenor/features/client_updates/providers/client_update_providers.dart';
import 'package:larenor/features/server/admin/presentation/server_admin_screen.dart';
import 'package:larenor/features/server/presentation/server_connection_screen.dart';
import 'package:larenor/features/server/presentation/server_vault_screen.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/backup/backup_test_storage.dart';
import '../features/client_updates/client_updates_test.dart' as updates;
import '../features/server/server_admin_test_support.dart';
import '../features/server/server_vault_test_support.dart';

enum _Screen { connect, account, admin, vault, updates }

void main() {
  for (final entry in [
    (
      'server-connect-tablet-light',
      const Size(1280, 900),
      false,
      _Screen.connect,
    ),
    (
      'server-account-tablet-dark',
      const Size(1280, 900),
      true,
      _Screen.account,
    ),
    (
      'server-admin-users-tablet-dark',
      const Size(1280, 900),
      true,
      _Screen.admin,
    ),
    (
      'server-vault-review-tablet-light',
      const Size(1280, 900),
      false,
      _Screen.vault,
    ),
    (
      'server-client-update-tablet-dark',
      const Size(1280, 900),
      true,
      _Screen.updates,
    ),
    ('server-admin-users-phone', const Size(320, 1000), false, _Screen.admin),
  ]) {
    testWidgets(
      '${entry.$1} renders actual widgets with synthetic account data',
      (tester) async {
        const out = String.fromEnvironment('DESIGN_PREVIEW_DIR');
        if (out.isNotEmpty) {
          await tester.runAsync(() async {
            final font = await rootBundle.load(
              'assets/fonts/Inter-Variable.ttf',
            );
            for (final family in [
              'Inter',
              'CupertinoSystemText',
              'CupertinoSystemDisplay',
            ]) {
              await (FontLoader(family)..addFont(Future.value(font))).load();
            }
            await (FontLoader('packages/cupertino_icons/CupertinoIcons')
                  ..addFont(
                    rootBundle.load(
                      'packages/cupertino_icons/assets/CupertinoIcons.ttf',
                    ),
                  ))
                .load();
          });
        }
        FlutterSecureStorage.setMockInitialValues({});
        SharedPreferences.setMockInitialValues({});
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        tester.view.physicalSize = entry.$2;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        final fixture = AdminFixture();
        fixture.users[0]['username'] = 'ev.yoneticisi';
        fixture.users[1]['username'] = 'salon.tablet';
        fixture.users[1]['mustChangePassword'] = true;
        fixture.respond = (request) async {
          expect(
            request.method,
            'GET',
            reason: 'A visual preview must never send a mutation.',
          );
          if (request.url.path.endsWith('/vault')) {
            return fixture.json({
              'revision': 7,
              'document': {'version': 1, 'snapshot': vaultSnapshot().toJson()},
            });
          }
          return fixture.defaultResponse(request);
        };
        if (entry.$4 == _Screen.connect) fixture.store.value = null;
        await fixture.account.initialize();
        final native = updates.FakeApi();
        final storage = MemoryBackupStorage(
          preferences: {'appearance': 'light'},
        );
        final boundary = GlobalKey();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              serverAccountControllerProvider.overrideWithValue(
                fixture.account,
              ),
              backupRepositoryProvider.overrideWithValue(
                BackupRepository(storage: storage),
              ),
              clientUpdateApiProvider.overrideWithValue(native),
              clientReleaseFactoryProvider.overrideWithValue(
                (source) => ClientReleaseRepository(
                  baseUrl: source.baseUrl,
                  accessToken: source.accessToken,
                  isCurrent: source.isCurrent,
                  clientFactory: () => MockClient((request) async {
                    expect(request.method, 'GET');
                    expect(
                      request.url.path,
                      '/prefix/api/v1/client/releases/latest',
                    );
                    return http.Response(
                      jsonEncode({
                        ...updates.releaseJson(),
                        'sizeBytes': 48318382,
                        'releaseNotes': 'Sunucu hesabı, güvenli yapılandırma kasası ve tablet deneyimi için iyileştirmeler.',
                      }),
                      200,
                      headers: {
                        'content-type': 'application/json; charset=utf-8',
                      },
                    );
                  }),
                ),
              ),
            ],
            child: CupertinoApp(
              locale: const Locale('tr'),
              theme: larenorTheme(
                brightness: entry.$3 ? Brightness.dark : Brightness.light,
              ),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (_, child) =>
                  RepaintBoundary(key: boundary, child: child!),
              home: switch (entry.$4) {
                _Screen.connect ||
                _Screen.account => const ServerConnectionScreen(),
                _Screen.admin => const ServerAdminScreen(),
                _Screen.vault => const ServerVaultScreen(),
                _Screen.updates => const ClientUpdatesScreen(),
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (entry.$4 == _Screen.connect) {
          await tester.enterText(
            find.byKey(const ValueKey('server-url')),
            'https://larenor.example.test',
          );
          await tester.enterText(
            find.byKey(const ValueKey('server-username')),
            'ev.yoneticisi',
          );
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pumpAndSettle();
        }
        if (entry.$4 == _Screen.vault) {
          final review = find.byKey(const ValueKey('server-vault-review'));
          await tester.ensureVisible(review);
          await tester.tap(review);
          await tester.pumpAndSettle();
          final apply = find.byKey(const ValueKey('server-vault-apply'));
          await tester.ensureVisible(apply);
          await tester.pumpAndSettle();
        }
        if (entry.$4 == _Screen.updates) {
          expect(
            find.byKey(const ValueKey('updates-download')),
            findsOneWidget,
          );
        }
        expect(tester.takeException(), isNull);
        expect(fixture.mutations, isEmpty);
        expect(storage.writes, isEmpty);
        expect(native.downloads, 0);
        expect(native.installs, 0);
        final visibleText = tester
            .widgetList<Text>(find.byType(Text))
            .map((item) => item.data ?? '')
            .join('\n');
        expect(visibleText, isNot(contains('synthetic_admin_access')));
        expect(visibleText, isNot(contains('synthetic_private_ha_secret')));
        if (out.isNotEmpty) {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await render.toImage();
            try {
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File('$out/${entry.$1}.png')
                  .writeAsBytes(bytes!.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
        }
        await tester.pumpWidget(const SizedBox.shrink());
        fixture.account.dispose();
        await native.events.close();
      },
    );
  }
}
