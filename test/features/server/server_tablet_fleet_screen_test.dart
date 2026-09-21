import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/features/server/tablet_fleet/presentation/server_tablet_fleet_screen.dart';
import 'package:larenor/features/settings/presentation/settings_split_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server_tablet_fleet_test.dart';

void main() {
  late TabletFleetFixture fixture;

  Future<void> mount(
    WidgetTester tester, {
    required String language,
    required double width,
  }) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'settings_pin': '1234'});
    fixture = TabletFleetFixture();
    await fixture.account.initialize();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 1100);
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
          home: ServerTabletFleetScreen(gateCurrent: () => true),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.account.dispose();
    });
  }

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      300,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 30,
    );
    await tester.pumpAndSettle();
  }

  SemanticsNode actionNode(WidgetTester tester, Finder button) =>
      tester.getSemantics(
        find.descendant(of: button, matching: find.byType(Text)).first,
      );

  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1280.0]) {
      testWidgets(
        'tablet admin remains accessible at $language $width with 2x text',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            await mount(tester, language: language, width: width);
            final l10n = AppLocalizations.of(
              tester.element(find.byType(ServerTabletFleetScreen)),
            );
            expect(find.text(l10n.serverTabletFleetTitle), findsWidgets);
            expect(find.text(l10n.serverTabletFleetStandard), findsOneWidget);
            expect(
              find.text(l10n.serverTabletFleetDeviceOwner),
              findsOneWidget,
            );
            expect(
              find.byKey(const ValueKey('tablet-restart-$standardTabletId')),
              findsNothing,
            );
            final standard = find.byKey(
              const ValueKey('tablet-refresh-$standardTabletId'),
            );
            await reveal(tester, standard);
            final standardNode = actionNode(tester, standard);
            expect(standardNode.flagsCollection.isButton, isTrue);
            expect(standardNode.rect.width, greaterThanOrEqualTo(48));
            expect(standardNode.rect.height, greaterThanOrEqualTo(48));

            final owner = find.byKey(
              const ValueKey('tablet-restart-$ownerTabletId'),
            );
            await reveal(tester, owner);
            final ownerNode = actionNode(tester, owner);
            expect(ownerNode.flagsCollection.isButton, isTrue);
            expect(ownerNode.rect.height, greaterThanOrEqualTo(48));
            Focus.of(
              tester.element(
                find.descendant(of: owner, matching: find.byType(Text)).first,
              ),
            ).requestFocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pumpAndSettle();
            expect(
              fixture.calls.where(
                (call) => call.url.path.endsWith('/commands'),
              ),
              hasLength(2),
            );
            expect(
              tester
                  .getSemantics(
                    find.byKey(const ValueKey('tablet-fleet-live-status')),
                  )
                  .flagsCollection
                  .isLiveRegion,
              isTrue,
            );
            expect(tester.takeException(), isNull);
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }

  testWidgets('TalkBack revoke requires confirmation and supports cancel', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await mount(tester, language: 'en', width: 600);
      final revoke = find.byKey(
        const ValueKey('tablet-revoke-$standardTabletId'),
      );
      await reveal(tester, revoke);
      final node = actionNode(tester, revoke);
      node.owner!.performAction(node.id, ui.SemanticsAction.tap);
      await tester.pumpAndSettle();
      expect(find.text('Revoke this tablet?'), findsOneWidget);
      final cancel = find.byKey(const ValueKey('tablet-revoke-cancel'));
      expect(tester.getSize(cancel).height, greaterThanOrEqualTo(48));
      await tester.tap(cancel);
      await tester.pumpAndSettle();
      expect(fixture.calls.where((call) => call.method == 'DELETE'), isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1280.0]) {
      testWidgets(
        'settings exposes exact gated tablet management $language $width 2x',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            SharedPreferences.setMockInitialValues({});
            FlutterSecureStorage.setMockInitialValues({'settings_pin': '1234'});
            fixture = TabletFleetFixture();
            await fixture.account.initialize();
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(width, 1100);
            addTearDown(tester.view.reset);
            await tester.pumpWidget(
              ProviderScope(
                overrides: [
                  serverAccountControllerProvider.overrideWithValue(
                    fixture.account,
                  ),
                ],
                child: CupertinoApp(
                  locale: Locale(language),
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: const TextScaler.linear(2)),
                    child: child!,
                  ),
                  home: SettingsSplitScreen(tabletFleetGateCurrent: () => true),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final l10n = AppLocalizations.of(
              tester.element(find.byType(SettingsSplitScreen)),
            );
            final entry = find.text(l10n.serverTabletFleetTitle).first;
            await tester.ensureVisible(entry);
            expect(tester.getSemantics(entry).flagsCollection.isButton, isTrue);
            expect(tester.getRect(entry).height, greaterThanOrEqualTo(48));
            Focus.of(tester.element(entry)).requestFocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pumpAndSettle();
            expect(find.byType(ServerTabletFleetScreen), findsOneWidget);
            expect(find.text(l10n.serverTabletFleetStandard), findsOneWidget);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
            fixture.account.dispose();
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }

  testWidgets('missing settings authority stays locked and makes no request', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({'settings_pin': '1234'});
      fixture = TabletFleetFixture();
      await fixture.account.initialize();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            serverAccountControllerProvider.overrideWithValue(fixture.account),
          ],
          child: CupertinoApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ServerTabletFleetScreen(gateCurrent: () => false),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final l10n = AppLocalizations.of(
        tester.element(find.byType(ServerTabletFleetScreen)),
      );
      expect(find.text(l10n.serverTabletFleetLocked), findsOneWidget);
      expect(
        fixture.calls.where((call) => call.url.path.contains('/tablet-fleet/')),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.account.dispose();
    } finally {
      semantics.dispose();
    }
  });
}
