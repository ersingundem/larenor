import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/data/ha_discovery.dart';
import 'package:larenor/shared/widgets/settings_action_tile.dart';
import 'package:larenor/features/auth/presentation/connect_screen.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/kiosk/presentation/kiosk_screen.dart';
import 'package:larenor/features/settings/presentation/panes/connection_pane.dart';
import 'package:larenor/features/settings/presentation/panes/settings_nav_row.dart';
import 'package:larenor/features/settings/presentation/settings_split_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

const address =
    'https://tablet-settings-accessibility-example.'
    'private-home-assistant-instance.example:8123';

class _NoDiscovery extends HaDiscoveryService {
  @override
  Future<void> start() async {}
}

class _Connection extends ConnectionConfig {
  _Connection(this.saved);
  final bool saved;
  @override
  Future<HaConnectionConfig?> build() async => saved
      ? const HaConnectionConfig(baseUrl: address, token: 'synthetic-ha-token')
      : null;
}

Future<void> _mount(
  WidgetTester tester,
  Widget child,
  String language,
  double width, {
  bool saved = false,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectionConfigProvider.overrideWith(() => _Connection(saved)),
        haDiscoveryFactoryProvider.overrideWithValue(_NoDiscovery.new),
      ],
      child: CupertinoApp(
        theme: larenorTheme(brightness: Brightness.light),
        locale: Locale(language),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: child,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _focus(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  Focus.of(tester.element(target)).requestFocus();
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  for (final language in ['en', 'tr']) {
    testWidgets('root confirmation blocks both tablet panes $language 2x', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        await _mount(tester, const SettingsSplitScreen(), language, 1200);
        final l10n = AppLocalizations.of(
          tester.element(find.byType(SettingsSplitScreen)),
        );
        final closed = showCupertinoDialog<void>(
          context: tester.element(find.byType(SettingsSplitScreen)),
          useRootNavigator: true,
          builder: (context) => CupertinoAlertDialog(
            title: Text(l10n.settingsSetPinTitle),
            content: const CupertinoTextField(autofocus: true),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10n.commonCancel),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(CupertinoAlertDialog), findsOneWidget);
        final cancel = find.widgetWithText(
          CupertinoDialogAction,
          l10n.commonCancel,
        );
        final cancelText = find.descendant(
          of: cancel,
          matching: find.byType(Text),
        );
        final node = tester.getSemantics(cancelText);
        final labels = <String>[];
        // Walk the exposed platform tree, including nodes outside the dialog.
        void walk(SemanticsNode current) {
          labels.add(current.label);
          current.visitChildren((child) {
            walk(child);
            return true;
          });
        }

        walk(node.owner!.rootSemanticsNode!);
        expect(
          labels.any((label) => label.contains(l10n.serverTitle)),
          isFalse,
        );
        expect(
          labels.any((label) => label.contains(l10n.commonNotConnected)),
          isFalse,
        );
        for (var i = 0; i < 4; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          expect(
            FocusManager.instance.primaryFocus!.context!
                .findAncestorWidgetOfExactType<CupertinoAlertDialog>(),
            isNotNull,
          );
        }
        await tester.tap(cancel);
        await tester.pumpAndSettle();
        expect(find.byType(CupertinoAlertDialog), findsNothing);
        expect(
          tester
              .getSemantics(find.text(l10n.serverTitle))
              .flagsCollection
              .isButton,
          isTrue,
        );
        await closed;
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        semantics.dispose();
      }
    });
  }
  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets(
        'settings keyboard category and Kiosk journey $language $width 2x',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            // Start disconnected so this independently exercises navigation.
            await _mount(tester, const SettingsSplitScreen(), language, width);
            final l10n = AppLocalizations.of(
              tester.element(find.byType(SettingsSplitScreen)),
            );
            final connection = find
                .descendant(
                  of: find.byType(SettingsActionTile),
                  matching: find.text(l10n.settingsCategoryConnection),
                )
                .first;
            final server = find.text(l10n.serverTitle).first;
            final display = find.text(l10n.settingsCategoryDisplay).first;
            final node = tester.getSemantics(connection);
            expect(node.flagsCollection.isButton, isTrue);
            expect(
              node.getSemanticsData().hasAction(ui.SemanticsAction.tap),
              isTrue,
            );
            expect(node.rect.height, greaterThanOrEqualTo(48));
            await _focus(tester, connection);
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            expect(Focus.of(tester.element(server)).hasPrimaryFocus, isTrue);
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            expect(Focus.of(tester.element(display)).hasPrimaryFocus, isTrue);
            await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
            expect(Focus.of(tester.element(server)).hasPrimaryFocus, isTrue);
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pumpAndSettle();
            final rows = find.byType(SettingsNavRow);
            final first = find
                .descendant(of: rows.first, matching: find.byType(Text))
                .first;
            await _focus(tester, first);
            for (var i = 0; i < 3; i++) {
              await tester.sendKeyEvent(LogicalKeyboardKey.tab);
              await tester.pumpAndSettle();
            }
            final kiosk = find.text(l10n.kioskTitle);
            expect(Focus.of(tester.element(kiosk)).hasPrimaryFocus, isTrue);
            expect(tester.getSemantics(kiosk).flagsCollection.isButton, isTrue);
            await tester.sendKeyEvent(LogicalKeyboardKey.space);
            await tester.pumpAndSettle();
            expect(find.byType(KioskScreen), findsOneWidget);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump();
            semantics.dispose();
          }
        },
      );

      testWidgets(
        'saved URL fits and opens actual connection editor $language $width 2x',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            await _mount(
              tester,
              const ConnectionPane(),
              language,
              width,
              saved: true,
            );
            expect(tester.takeException(), isNull);
            final value = find.text(address);
            final title = find.text(
              AppLocalizations.of(tester.element(find.byType(ConnectionPane)))
                  .settingsHaServer,
            );
            final node = tester.getSemantics(title);
            expect(node.flagsCollection.isButton, isTrue);
            expect(node.label.split(address).length - 1, 1);
            expect(tester.getRect(value).right, lessThanOrEqualTo(width));
            expect(tester.getSize(title).width, greaterThan(48));
            await _focus(tester, title);
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pumpAndSettle();
            expect(find.byType(ConnectScreen), findsOneWidget);
            expect(
              tester
                  .widget<ConnectScreen>(find.byType(ConnectScreen))
                  .initialUrl,
              address,
            );
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump();
            semantics.dispose();
          }
        },
      );
    }
  }
}
