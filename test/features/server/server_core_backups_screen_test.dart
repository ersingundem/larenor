import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/core_backups/presentation/server_core_backups_screen.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server_core_backups_test.dart';

void main() {
  Future<BackupFixture> mount(
    WidgetTester tester, {
    required String language,
    required double width,
    Map<String, dynamic>? response,
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

  for (final (language, width) in [('en', 600.0), ('tr', 1280.0)]) {
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
}
