import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/features/settings/presentation/settings_split_screen.dart';
import 'package:larenor/features/workshop/presentation/workshop_route.dart';
import 'package:larenor/features/workshop/presentation/workshop_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import '../server/server_admin_test_support.dart';

void main() {
  late AdminFixture fixture;

  Future<void> mount(
    WidgetTester tester,
    Widget home, {
    String language = 'en',
    double width = 600,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 1000);
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
          home: home,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() async {
    fixture = AdminFixture();
    fixture.respond = (request) async {
      if (request.method == 'GET' &&
          request.url.path.endsWith(
            '/workshop/${'a' * 32}/${'b' * 32}/printers',
          )) {
        return fixture.json({'schemaVersion': 1, 'printers': []});
      }
      return fixture.defaultResponse(request);
    };
    await fixture.account.initialize();
  });

  tearDown(() => fixture.account.dispose());

  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1280.0]) {
      testWidgets(
        'Settings discovers authenticated workshop $language $width 2x',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            await mount(
              tester,
              SettingsSplitScreen(workshopGateCurrent: () => true),
              language: language,
              width: width,
            );
            final l10n = AppLocalizations.of(
              tester.element(find.byType(SettingsSplitScreen)),
            );
            final entry = find.text(l10n.settingsCategoryWorkshop).first;
            await tester.ensureVisible(entry);
            expect(tester.getSemantics(entry).flagsCollection.isButton, isTrue);
            expect(tester.getRect(entry).height, greaterThanOrEqualTo(48));
            Focus.of(tester.element(entry)).requestFocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pumpAndSettle();
            expect(find.byType(WorkshopRoute), findsOneWidget);
            expect(find.byType(WorkshopScreen), findsOneWidget);
            final calls = fixture.calls.where(
              (call) => call.url.path.contains('/workshop/'),
            );
            expect(calls, hasLength(1));
            expect(
              calls.single.headers['authorization'],
              'Bearer synthetic_admin_access_12345',
            );
            expect(tester.takeException(), isNull);
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }

  testWidgets('gate and account changes retire workshop callbacks', (
    tester,
  ) async {
    await mount(tester, WorkshopRoute(gateCurrent: () => false));
    expect(find.byType(WorkshopScreen), findsNothing);
    expect(
      fixture.calls.where((call) => call.url.path.contains('/workshop/')),
      isEmpty,
    );

    final delayed = Completer<http.Response>();
    fixture.respond = (request) async {
      if (request.url.path.contains('/workshop/')) {
        return delayed.future;
      }
      return fixture.defaultResponse(request);
    };
    await tester.pumpWidget(const SizedBox.shrink());
    await mount(tester, WorkshopRoute(gateCurrent: () => true));
    await tester.pump();
    await fixture.account.signOut();
    delayed.complete(fixture.json({'schemaVersion': 1, 'printers': []}));
    await tester.pumpAndSettle();
    expect(find.byType(WorkshopScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
