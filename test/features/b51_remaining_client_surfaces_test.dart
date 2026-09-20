import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/features/auth/data/ha_discovery.dart';
import 'package:larenor/features/auth/presentation/connect_screen.dart';
import 'package:larenor/features/inventory/data/inventory_controller.dart';
import 'package:larenor/features/inventory/presentation/inventory_screen.dart';
import 'package:larenor/features/media/arr/data/models/arr_lookup_result.dart';
import 'package:larenor/features/media/arr/data/models/arr_picker_options.dart';
import 'package:larenor/features/media/arr/presentation/widgets/arr_add_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/app_page_scaffold.dart';
import 'package:larenor/shared/widgets/settings_action_tile.dart';
import 'package:larenor/shared/widgets/settings_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'inventory/inventory_controller_test.dart' show FakeInventoryGateway;
import 'inventory/inventory_models_test.dart' show context, core, home, itemId;

class _NoDiscovery extends HaDiscoveryService {
  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}

const _result = ArrLookupResult(
  title: 'Living room movie',
  remoteId: 42,
  raw: {'title': 'Living room movie', 'tmdbId': 42},
);

Future<void> _mount(
  WidgetTester tester, {
  required Locale locale,
  required double width,
  required Widget home,
}) async {
  tester.view.physicalSize = Size(width, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    CupertinoApp(
      theme: larenorTheme(),
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(2)),
        child: child!,
      ),
      home: home,
    ),
  );
  await tester.pumpAndSettle();
}

void _expectAction(WidgetTester tester, String key) {
  final finder = find.byKey(ValueKey(key));
  expect(finder, findsOneWidget);
  final semantics = tester.getSemantics(finder);
  expect(semantics.flagsCollection.isButton, isTrue);
  expect(semantics.rect.width, greaterThanOrEqualTo(48));
  expect(semantics.rect.height, greaterThanOrEqualTo(48));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1200.0]) {
      testWidgets(
        'HA connect ${locale.languageCode} fits ${width.toInt()} at 2x and submits with Done',
        (tester) async {
          final semantics = tester.ensureSemantics();
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                haDiscoveryFactoryProvider.overrideWithValue(_NoDiscovery.new),
              ],
              child: CupertinoApp(
                theme: larenorTheme(),
                locale: locale,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: const TextScaler.linear(2)),
                  child: child!,
                ),
                home: const ConnectScreen(initialUrl: 'https://bad host'),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(AppSurface), findsOneWidget);
          expect(find.byType(SettingsSection), findsAtLeastNWidgets(1));
          _expectAction(tester, 'ha-connect-submit');
          await tester.enterText(
            find.byType(CupertinoTextField).at(1),
            'fixture-token',
          );
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await tester.pumpAndSettle();
          final l10n = AppLocalizations.of(
            tester.element(find.byType(ConnectScreen)),
          );
          final error = find.text(l10n.connectErrorUrl);
          expect(error, findsOneWidget);
          expect(
            tester.getSemantics(error).flagsCollection.isLiveRegion,
            isTrue,
          );
          expect(tester.takeException(), isNull);
          semantics.dispose();
        },
      );

      testWidgets(
        'inventory ${locale.languageCode} fits ${width.toInt()} at 2x and uses shared actions',
        (tester) async {
          final controller = InventoryController(
            gateway: FakeInventoryGateway(),
            context: context,
            canReadGrants: true,
            isCurrent: () => true,
          );
          addTearDown(controller.dispose);
          await _mount(
            tester,
            locale: locale,
            width: width,
            home: Builder(
              builder: (context) => InventoryScreen(
                controller: controller,
                strings: InventoryStrings.fromLocalizations(
                  AppLocalizations.of(context),
                ),
              ),
            ),
          );
          expect(find.byType(AppSurface), findsOneWidget);
          expect(find.byType(SettingsSection), findsAtLeastNWidgets(1));
          _expectAction(tester, 'inventory-open');
          await tester.enterText(
            find.byKey(const ValueKey('inventory-manual-entry')),
            'larenor:inventory:v1:$core:$home:$itemId',
          );
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await tester.pumpAndSettle();
          expect(find.text('Kahve değirmeni'), findsWidgets);
          final item = find.byKey(ValueKey('inventory-item-$itemId'));
          _expectAction(tester, 'inventory-item-$itemId');
          Focus.of(
            tester.element(
              find
                  .descendant(of: item, matching: find.text('Kahve değirmeni'))
                  .first,
            ),
          ).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets(
        'ARR add ${locale.languageCode} fits ${width.toInt()} at 2x and opens by Enter',
        (tester) async {
          await _mount(
            tester,
            locale: locale,
            width: width,
            home: Builder(
              builder: (context) {
                final l10n = AppLocalizations.of(context);
                return ArrAddScreen(
                  title: l10n.commonAdd,
                  searchHint: l10n.arrSearchToAdd,
                  onLookup: (_) async => const [_result],
                  loadQualityProfiles: () async => const [
                    ArrQualityProfile(id: 1, name: 'HD'),
                  ],
                  loadRootFolders: () async => const [
                    ArrRootFolder(id: 2, path: '/media'),
                  ],
                  onAdd: (_, _, _, _) async {},
                );
              },
            ),
          );
          expect(find.byType(AppSurface), findsOneWidget);
          expect(find.byType(SettingsSection), findsAtLeastNWidgets(1));
          final search = find.byKey(const ValueKey('arr-add-search'));
          expect(
            tester.getSemantics(search).rect.height,
            greaterThanOrEqualTo(48),
          );
          await tester.enterText(search, 'living room');
          await tester.testTextInput.receiveAction(TextInputAction.search);
          await tester.pumpAndSettle();
          expect(find.byType(SettingsActionTile), findsOneWidget);
          _expectAction(tester, 'arr-add-result-42');
          final title = find.text(_result.title);
          Focus.of(tester.element(title)).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(find.byType(CupertinoActionSheet), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('captured HA connect action expires across background', (
    tester,
  ) async {
    var requests = 0;
    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              haDiscoveryFactoryProvider.overrideWithValue(_NoDiscovery.new),
            ],
            child: const CupertinoApp(home: ConnectScreen()),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(CupertinoTextField).at(1),
          'fixture-token',
        );
        final old = tester
            .widget<CupertinoButton>(
              find.byKey(const ValueKey('ha-connect-submit')),
            )
            .onPressed!;
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        old();
        await tester.pumpAndSettle();
        expect(requests, 0);
        expect(tester.takeException(), isNull);
      },
      () => MockClient((_) async {
        requests++;
        return http.Response('{"message":"API running."}', 200);
      }),
    );
  });
}
