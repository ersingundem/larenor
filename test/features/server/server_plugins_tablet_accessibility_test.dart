import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/shared/widgets/settings_section.dart';
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
  late GlobalKey boundary;
  Future<void> mount(
    WidgetTester tester, {
    String locale = 'en',
    double width = 600,
    bool dark = false,
    bool safeInsets = false,
  }) async {
    await loadFonts(tester);
    boundary = GlobalKey();
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'settings_pin': '1234'});
    fixture = PluginJobsFixture()..configured = false;
    await fixture.account.initialize();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 1000);
    if (safeInsets) {
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 16);
      tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 16);
    }
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
            child: RepaintBoundary(key: boundary, child: child!),
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
  SemanticsNode actionSemantics(WidgetTester tester, Finder button) =>
      tester.getSemantics(
        find.descendant(of: button, matching: find.byType(Text)).first,
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
              actionSemantics(tester, preview).flagsCollection.isHeader,
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
          for (final entry in const {
            'jellyfin': 'Jellyfin',
            'seerr': 'Seerr',
            'sonarr': 'Sonarr',
            'radarr': 'Radarr',
            'qbittorrent': 'qBittorrent',
          }.entries) {
            final preview = key('plugin-review-${entry.key}');
            await visible(tester, preview);
            final label =
                '${entry.value} · ${AppLocalizations.of(tester.element(preview)).serverPluginsPreview}';
            final node = actionSemantics(tester, preview);
            expect(node.label, label);
            expect(node.flagsCollection.isButton, isTrue);
            expect(node.flagsCollection.isHeader, isFalse);
            expect(node.rect.width, greaterThanOrEqualTo(48));
            expect(node.rect.height, greaterThanOrEqualTo(48));
            expect(find.bySemanticsLabel(label), findsOneWidget);
          }
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
            final node = actionSemantics(tester, refresh);
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
  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1280.0]) {
      testWidgets(
        'named preview opens actual form and keyboard cancel has zero effect $language $width 2x',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            await mount(tester, locale: language, width: width);
            final preview = key('plugin-review-jellyfin');
            await visible(tester, preview);
            final l10n = AppLocalizations.of(tester.element(preview));
            final node = actionSemantics(tester, preview);
            node.owner!.performAction(node.id, ui.SemanticsAction.tap);
            await tester.pumpAndSettle();
            expect(key('plugin-setting-instanceName'), findsOneWidget);
            final labels = <String>[];
            void visit(SemanticsNode current) {
              labels.add(current.label);
              current.visitChildren((child) {
                visit(child);
                return true;
              });
            }

            visit(
              tester
                  .getSemantics(key('plugin-preview-submit'))
                  .owner!
                  .rootSemanticsNode!,
            );
            expect(
              labels,
              isNot(contains('Jellyfin · ${l10n.serverPluginsPreview}')),
            );
            final cancel = find.widgetWithText(
              CupertinoButton,
              l10n.commonCancel,
            );
            await visible(tester, cancel);
            expect(
              actionSemantics(tester, cancel).flagsCollection.isButton,
              isTrue,
            );
            expect(tester.getSize(cancel).height, greaterThanOrEqualTo(48));
            focus(tester, cancel).requestFocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pumpAndSettle();
            expect(key('plugin-setting-instanceName'), findsNothing);
            expect(preview, findsOneWidget);
            expect(fixture.mutations, isEmpty);
            expect(tester.takeException(), isNull);
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }
  testWidgets(
    'busy catalogue actions have no semantic action and retained callbacks stay inert',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final pending = Completer<http.Response>();
      try {
        await mount(tester);
        final jobs = key('plugins-jobs');
        final retained = tester.widget<CupertinoButton>(jobs).onPressed!;
        final normal = fixture.respond!;
        fixture.respond = (request) =>
            request.url.path.endsWith('/plugins/catalog')
            ? pending.future
            : normal(request);
        await tester.tap(key('plugins-refresh'));
        await tester.pump();
        await tester.pump();
        expect(tester.widget<CupertinoButton>(jobs).onPressed, isNull);
        final node = actionSemantics(tester, jobs);
        expect(node.flagsCollection.isButton, isTrue);
        expect(node.flagsCollection.isEnabled, ui.Tristate.isFalse);
        expect(
          node.getSemanticsData().hasAction(ui.SemanticsAction.tap),
          isFalse,
        );
        final calls = fixture.calls.length;
        node.owner!.performAction(node.id, ui.SemanticsAction.tap);
        retained();
        await tester.pump();
        expect(fixture.calls.length, calls);
        expect(find.byType(ServerPluginJobsScreen), findsNothing);
        pending.complete(
          fixture.pluginResponse(
            http.Request(
              'GET',
              Uri.parse(
                'https://fixture.invalid/prefix/api/v1/admin/plugins/catalog',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(fixture.mutations, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        if (!pending.isCompleted) pending.complete(http.Response('{}', 503));
        semantics.dispose();
      }
    },
  );
  testWidgets('already visible toolbar Tab preserves scroll offset', (
    tester,
  ) async {
    await mount(tester, width: 1280);
    final media = key('plugins-media'), jobs = key('plugins-jobs');
    final position = Scrollable.of(tester.element(media)).position;
    position.jumpTo(20);
    await tester.pumpAndSettle();
    final top = tester.getRect(find.byType(CupertinoNavigationBar)).bottom;
    for (final button in [media, jobs]) {
      final ring = tester.getRect(button).inflate(4);
      expect(ring.top, greaterThanOrEqualTo(top));
      expect(ring.bottom, lessThan(1000));
    }
    focus(tester, media).requestFocus();
    await tester.pumpAndSettle();
    expect(position.pixels, 20);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(focus(tester, jobs).hasPrimaryFocus, isTrue);
    expect(position.pixels, 20);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(focus(tester, media).hasPrimaryFocus, isTrue);
    expect(position.pixels, 20);
    expect(fixture.mutations, isEmpty);
    expect(tester.takeException(), isNull);
  });
  for (final dark in [false, true]) {
    for (final width in [600.0, 1280.0]) {
      testWidgets(
        'real forward and backward Tab keeps catalogue focus inside viewport $dark $width 2x',
        (tester) async {
          await mount(
            tester,
            locale: dark ? 'tr' : 'en',
            width: width,
            dark: dark,
            safeInsets: width == 1280,
          );
          final start = key('plugins-connect');
          await visible(tester, start);
          focus(tester, start).requestFocus();
          await tester.pump();
          const ids = ['jellyfin', 'seerr', 'sonarr', 'radarr', 'qbittorrent'];
          Future<void> check(String id) async {
            final button = key('plugin-review-$id');
            expect(button, findsOneWidget);
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
            final side =
                ((tester.widget<DecoratedBox>(decorations.first).decoration
                                as ShapeDecoration)
                            .shape
                        as OutlinedBorder)
                    .side;
            expect(side.width, greaterThan(0));
            final ring = tester.getRect(button).inflate(side.width);
            final top = tester
                .getRect(find.byType(CupertinoNavigationBar))
                .bottom;
            expect(
              ring.top,
              greaterThanOrEqualTo(top),
              reason: '$id focus must not hide behind navigation bar',
            );
            expect(
              ring.bottom,
              lessThanOrEqualTo(
                tester.view.physicalSize.height - tester.view.padding.bottom,
              ),
              reason: '$id focus must fit visible viewport',
            );
          }

          for (final id in ids) {
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.pumpAndSettle();
            await check(id);
          }
          for (final id in ids.reversed.skip(1)) {
            await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
            await tester.pumpAndSettle();
            await check(id);
          }
          expect(fixture.mutations, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
      testWidgets(
        'first and last catalogue action focus fits card $dark $width 2x',
        (tester) async {
          await mount(
            tester,
            locale: dark ? 'tr' : 'en',
            width: width,
            dark: dark,
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          for (final id in ['jellyfin', 'qbittorrent']) {
            final button = key('plugin-review-$id');
            await visible(tester, button);
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            focus(tester, button).requestFocus();
            await tester.pumpAndSettle();
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
            final section = find
                .ancestor(of: button, matching: find.byType(SettingsSection))
                .first;
            final area = tester.getRect(section);
            final ring = tester.getRect(button).inflate(outline.side.width);
            expect(ring.left, greaterThanOrEqualTo(area.left));
            expect(ring.right, lessThanOrEqualTo(area.right));
            expect(ring.top, greaterThanOrEqualTo(area.top));
            expect(ring.bottom, lessThanOrEqualTo(area.bottom));
            final background = CupertinoColors.secondarySystemGroupedBackground
                .resolveFrom(tester.element(button));
            final a = Color.alphaBlend(
                  outline.side.color,
                  background,
                ).computeLuminance(),
                b = background.computeLuminance();
            expect(
              ((a > b ? a : b) + .05) / ((a < b ? a : b) + .05),
              greaterThanOrEqualTo(3),
            );
            const output = String.fromEnvironment('PLUGINS_TABLET_PREVIEW_DIR');
            if (output.isNotEmpty && id == 'jellyfin') {
              await tester.runAsync(() async {
                final render =
                    boundary.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary;
                final picture = await render.toImage(pixelRatio: 1);
                final bytes = await picture.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                await File(
                  '$output/plugins-${dark ? 'tr-dark' : 'en-light'}-${width.toInt()}-2x.png',
                ).writeAsBytes(bytes!.buffer.asUint8List());
                picture.dispose();
              });
            }
          }
          expect(tester.takeException(), isNull);
          expect(fixture.mutations, isEmpty);
        },
      );
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
