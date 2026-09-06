import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/features/server/plugins/presentation/server_plugins_screen.dart';
import 'package:larenor/features/server/plugins/presentation/server_plugin_jobs_screen.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../home_resources/home_resources_tablet_test.dart' show loadFonts;
import 'server_plugin_jobs_test_support.dart';

void main() {
  late PluginJobsFixture fixture;
  Future<void> mount(
    WidgetTester tester, {
    String locale = 'en',
    double width = 600,
    bool dark = false,
  }) async {
    await loadFonts(tester);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'settings_pin': '1234'});
    fixture = PluginJobsFixture()..configured = false;
    await fixture.account.initialize();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 1000);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(fixture.account),
        ],
        child: CupertinoApp(
          theme: larenorTheme(
            brightness: dark ? Brightness.dark : Brightness.light,
          ),
          locale: Locale(locale),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: const ServerPluginsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.account.dispose();
    });
  }

  Finder key(String value) => find.byKey(ValueKey(value));
  Future<void> visible(WidgetTester tester, Finder finder) async {
    if (finder.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        finder,
        300,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 30,
      );
    }
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
  }

  FocusNode focus(WidgetTester tester, Finder finder) => Focus.of(
    tester.element(
      find.descendant(of: finder, matching: find.byType(Text)).first,
    ),
  );
  for (final locale in ['en', 'tr']) {
    for (final width in [600.0, 1280.0]) {
      testWidgets(
        'component title remains a heading separate from preview $locale $width 2x',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            await mount(tester, locale: locale, width: width);
            final heading = find.text('Jellyfin');
            await visible(tester, heading);
            expect(
              tester.getSemantics(heading).flagsCollection.isHeader,
              isTrue,
            );
            final preview = key('plugin-review-jellyfin');
            await visible(tester, preview);
            expect(
              tester.getSemantics(preview).flagsCollection.isHeader,
              isFalse,
            );
            expect(fixture.mutations, isEmpty);
            expect(tester.takeException(), isNull);
          } finally {
            semantics.dispose();
          }
        },
      );
      testWidgets('preview action names its component once $locale $width 2x', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        try {
          await mount(tester, locale: locale, width: width);
          final preview = key('plugin-review-jellyfin');
          await visible(tester, preview);
          final label =
              'Jellyfin · ${AppLocalizations.of(tester.element(preview)).serverPluginsPreview}';
          final node = tester.getSemantics(preview);
          expect(node.label, label);
          expect(node.flagsCollection.isButton, isTrue);
          expect(node.rect.width, greaterThanOrEqualTo(48));
          expect(node.rect.height, greaterThanOrEqualTo(48));
          expect(find.bySemanticsLabel(label), findsOneWidget);
          expect(fixture.mutations, isEmpty);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });
      testWidgets(
        'keyboard Tab Enter and Space preserve actual jobs transition $locale $width 2x',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            await mount(tester, locale: locale, width: width);
            final jobs = key('plugins-jobs');
            await visible(tester, jobs);
            focus(tester, jobs).requestFocus();
            await tester.pumpAndSettle();
            await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
            await tester.pumpAndSettle();
            expect(focus(tester, key('plugins-media')).hasPrimaryFocus, isTrue);
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.pumpAndSettle();
            expect(focus(tester, jobs).hasPrimaryFocus, isTrue);
            final old = tester.widget<CupertinoButton>(jobs).onPressed!;
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pumpAndSettle();
            expect(find.byType(ServerPluginJobsScreen), findsOneWidget);
            expect(find.byType(ServerPluginsScreen), findsNothing);
            final count = fixture.calls.length;
            old();
            await tester.pumpAndSettle();
            expect(fixture.calls.length, count);
            final refresh = key('jobs-refresh');
            await visible(tester, refresh);
            final node = tester.getSemantics(refresh);
            expect(node.flagsCollection.isButton, isTrue);
            expect(node.rect.height, greaterThanOrEqualTo(48));
            focus(tester, refresh).requestFocus();
            await tester.pumpAndSettle();
            await tester.sendKeyEvent(LogicalKeyboardKey.space);
            await tester.pumpAndSettle();
            expect(fixture.calls.length, count + 2);
            expect(fixture.mutations, isEmpty);
            expect(tester.takeException(), isNull);
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }
  for (final dark in [false, true]) {
    for (final width in [600.0, 1280.0]) {
      testWidgets(
        'plugin keyboard focus meets contrast and stays inside viewport $dark $width 2x',
        (tester) async {
          await mount(tester, locale: 'tr', width: width, dark: dark);
          final button = key('plugins-jobs');
          await visible(tester, button);
          focus(tester, key('plugins-media')).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pumpAndSettle();
          expect(focus(tester, button).hasPrimaryFocus, isTrue);
          final decorations = find.descendant(
            of: button,
            matching: find.byWidgetPredicate(
              (w) =>
                  w is DecoratedBox &&
                  w.decoration is ShapeDecoration &&
                  (w.decoration as ShapeDecoration).shape is OutlinedBorder,
            ),
          );
          final outline =
              (tester.widget<DecoratedBox>(decorations.first).decoration
                          as ShapeDecoration)
                      .shape
                  as OutlinedBorder;
          expect(outline.side.width, greaterThan(0));
          final background = CupertinoTheme.of(tester.element(button))
              .scaffoldBackgroundColor;
          final actual = Color.alphaBlend(outline.side.color, background);
          final a = actual.computeLuminance(),
              b = background.computeLuminance();
          final contrast = ((a > b ? a : b) + .05) / ((a < b ? a : b) + .05);
          expect(
            contrast,
            greaterThanOrEqualTo(3),
            reason: 'actual painted focus against Larenor canvas',
          );
          final rect = tester.getRect(button).inflate(outline.side.width);
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(width));
          expect(rect.bottom, lessThanOrEqualTo(1000));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
