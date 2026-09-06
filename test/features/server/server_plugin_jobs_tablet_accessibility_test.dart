import 'dart:async';
import 'dart:convert' show jsonDecode;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/server/plugins/presentation/server_plugin_jobs_screen.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../home_resources/home_resources_tablet_test.dart' show loadFonts;
import 'server_plugin_jobs_test_support.dart';

class _JobsFixture extends PluginJobsFixture {
  final records = [
    for (var i = 0; i < 4; i++)
      {
        ...pluginJobJson(),
        'id': String.fromCharCode(97 + i) * 32,
        'createdAt': '2026-09-05T0${9 - i}:00:00.000Z',
      },
  ];
  @override
  http.Response pluginResponse(http.Request request) {
    final path = request.url.path;
    if (request.method == 'GET' && path.endsWith('/jobs')) {
      return json({'jobs': records, 'nextBefore': null});
    }
    for (final record in records) {
      if (request.method == 'GET' && path.endsWith('/jobs/${record['id']}')) {
        return json({'job': record});
      }
    }
    final response = super.pluginResponse(request);
    if (request.method == 'POST' &&
        path.endsWith('/jobs/${records.first['id']}/cancel')) {
      records[0] = job;
    }
    return response;
  }
}

void main() {
  late _JobsFixture fixture;
  late GlobalKey boundary;
  Future<void> mount(
    WidgetTester tester, {
    String language = 'en',
    double width = 600,
    bool dark = false,
    bool completed = false,
    double scale = 2,
    bool safeInsets = false,
    AppInteractionController? interaction,
  }) async {
    await loadFonts(tester);
    boundary = GlobalKey();
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'settings_pin': '1234'});
    fixture = _JobsFixture()..configured = false;
    if (completed) {
      fixture.records[0] = pluginJobJson(state: 'succeeded', revision: 3);
    }
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
          locale: Locale(language),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: RepaintBoundary(
              key: boundary,
              child: interaction == null
                  ? child!
                  : AppInteractionScope(controller: interaction, child: child!),
            ),
          ),
          home: const ServerPluginJobsScreen(),
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
  Finder caption(Finder button) =>
      find.descendant(of: button, matching: find.byType(Text)).first;
  SemanticsNode action(WidgetTester tester, Finder button) =>
      tester.getSemantics(caption(button));
  FocusNode focus(WidgetTester tester, Finder button) =>
      Focus.of(tester.element(caption(button)));
  Future<void> visible(WidgetTester tester, Finder target) async {
    if (target.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        target,
        300,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 30,
      );
    }
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
  }

  Future<void> select(WidgetTester tester) async {
    final button = key('job-view-${'a' * 32}');
    await visible(tester, button);
    focus(tester, button).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(key('job-refresh'), findsOneWidget);
  }

  Future<void> preview(WidgetTester tester, String name) async {
    const output = String.fromEnvironment('JOBS_TABLET_PREVIEW_DIR');
    if (output.isEmpty) return;
    await tester.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$output/$name.png').writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1280.0]) {
      testWidgets(
        'history heading is separate from actions $language $width 2x',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            await mount(tester, language: language, width: width);
            final l10n = AppLocalizations.of(
              tester.element(key('jobs-refresh')),
            );
            expect(
              tester
                  .getSemantics(find.text(l10n.serverJobsHistory))
                  .flagsCollection
                  .isHeader,
              isTrue,
            );
            expect(
              action(tester, key('jobs-refresh')).flagsCollection.isHeader,
              isFalse,
            );
            await visible(tester, find.text('Jellyfin').first);
            expect(
              tester
                  .getSemantics(find.text('Jellyfin').first)
                  .flagsCollection
                  .isHeader,
              isTrue,
            );
            expect(fixture.mutations, isEmpty);
            expect(tester.takeException(), isNull);
          } finally {
            semantics.dispose();
          }
        },
      );
      testWidgets(
        'history View names each observed service state and time $language $width 2x',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            await mount(tester, language: language, width: width);
            final l10n = AppLocalizations.of(
              tester.element(key('jobs-refresh')),
            );
            for (final record in fixture.records) {
              final button = key('job-view-${record['id']}');
              await visible(tester, button);
              final date = DateFormat.yMd(l10n.localeName).add_Hm().format(
                DateTime.parse(record['createdAt'] as String).toLocal(),
              );
              final label =
                  'Jellyfin · ${l10n.serverJobsQueued} · $date · ${l10n.serverJobsView}';
              final node = action(tester, button);
              expect(node.label, label);
              expect(node.flagsCollection.isButton, isTrue);
              expect(node.flagsCollection.isHeader, isFalse);
              expect(node.rect.width, greaterThanOrEqualTo(48));
              expect(node.rect.height + 1e-9, greaterThanOrEqualTo(48));
              expect(find.bySemanticsLabel(label), findsOneWidget);
            }
            expect(fixture.mutations, isEmpty);
            expect(tester.takeException(), isNull);
          } finally {
            semantics.dispose();
          }
        },
      );
      testWidgets(
        'keyboard detail refresh and cancellation Back preserve zero writes $language $width 2x',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            await mount(tester, language: language, width: width);
            await select(tester);
            final refresh = key('job-refresh');
            await visible(tester, refresh);
            final l10n = AppLocalizations.of(tester.element(refresh));
            final before = fixture.calls
                .where((r) => r.url.path.endsWith('/jobs/${'a' * 32}'))
                .length;
            focus(tester, refresh).requestFocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.space);
            await tester.pumpAndSettle();
            expect(
              fixture.calls
                  .where((r) => r.url.path.endsWith('/jobs/${'a' * 32}'))
                  .length,
              before + 1,
            );
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.pumpAndSettle();
            expect(focus(tester, key('jobs-cancel')).hasPrimaryFocus, isTrue);
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pumpAndSettle();
            expect(key('jobs-cancel-confirm'), findsOneWidget);
            final back = find.widgetWithText(
              CupertinoDialogAction,
              l10n.commonBack,
            );
            final node = action(tester, back);
            expect(node.label, l10n.commonBack);
            expect(node.flagsCollection.isButton, isTrue);
            expect(tester.getSize(back).height, greaterThanOrEqualTo(48));
            focus(tester, back).requestFocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pumpAndSettle();
            expect(key('jobs-cancel-confirm'), findsNothing);
            expect(key('job-refresh'), findsOneWidget);
            expect(fixture.mutations, isEmpty);
            expect(tester.takeException(), isNull);
          } finally {
            semantics.dispose();
          }
        },
      );
      testWidgets(
        'completed detail headings remain semantic headings $language $width 2x',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            await mount(
              tester,
              language: language,
              width: width,
              completed: true,
            );
            await select(tester);
            final l10n = AppLocalizations.of(
              tester.element(key('job-refresh')),
            );
            for (final label in [
              'Jellyfin',
              l10n.serverJobsResults,
              l10n.serverJobsEvents,
            ]) {
              final title = find.text(label);
              await visible(tester, title);
              expect(
                tester.getSemantics(title).flagsCollection.isHeader,
                isTrue,
              );
            }
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
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          'actual modal semantic hit area and keyboard confirm $language $width ${scale}x',
          (tester) async {
            final semantics = tester.ensureSemantics();
            try {
              await mount(
                tester,
                language: language,
                width: width,
                scale: scale,
                dark: language == 'tr',
              );
              await select(tester);
              final cancel = key('jobs-cancel');
              await visible(tester, cancel);
              final l10n = AppLocalizations.of(tester.element(cancel));
              focus(tester, cancel).requestFocus();
              await tester.pump();
              await tester.sendKeyEvent(LogicalKeyboardKey.enter);
              await tester.pumpAndSettle();
              final confirm = key('jobs-cancel-confirm');
              final back = find.widgetWithText(
                CupertinoDialogAction,
                l10n.commonBack,
              );
              final nodes = <SemanticsNode>[];
              void visit(SemanticsNode node) {
                nodes.add(node);
                node.visitChildren((child) {
                  visit(child);
                  return true;
                });
              }

              visit(action(tester, confirm).owner!.rootSemanticsNode!);
              for (final label in [l10n.commonBack, l10n.serverJobsCancel]) {
                final matching = nodes
                    .where(
                      (n) =>
                          !n.isMergedIntoParent &&
                          n.getSemanticsData().label == label,
                    )
                    .toList();
                expect(matching, hasLength(1));
                final node = matching.single;
                expect(
                  node.getSemanticsData().flagsCollection.isButton,
                  isTrue,
                );
                expect(
                  node.getSemanticsData().hasAction(ui.SemanticsAction.tap),
                  isTrue,
                );
                expect(node.rect.width, greaterThanOrEqualTo(48));
                expect(node.rect.height + 1e-9, greaterThanOrEqualTo(48));
              }
              expect(
                nodes.where(
                  (n) =>
                      !n.isMergedIntoParent &&
                      n.getSemanticsData().flagsCollection.isButton &&
                      n.getSemanticsData().hasAction(ui.SemanticsAction.tap),
                ),
                hasLength(2),
              );
              if (scale == 1) {
                // The short Back label fits at the native 17px font size.
                // Measure painted geometry, not only the unscaled Text widget.
                final text = tester.renderObject<RenderParagraph>(
                  caption(back),
                );
                final painted = MatrixUtils.transformRect(
                  text.getTransformTo(null),
                  Offset.zero & text.size,
                );
                expect(
                  painted.height / text.size.height,
                  closeTo(1, 1e-9),
                  reason: 'short dialog label must keep its normal painted font size',
                );
              }
              final detector = tester.widget<FocusableActionDetector>(
                find.descendant(
                  of: confirm,
                  matching: find.byType(FocusableActionDetector),
                ),
              );
              final oldKeyboard = detector.actions![ActivateIntent]!;
              focus(tester, back).requestFocus();
              await tester.pump();
              await tester.sendKeyEvent(LogicalKeyboardKey.tab);
              await tester.pumpAndSettle();
              expect(focus(tester, confirm).hasPrimaryFocus, isTrue);
              await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
              await tester.sendKeyEvent(LogicalKeyboardKey.tab);
              await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
              await tester.pumpAndSettle();
              expect(focus(tester, back).hasPrimaryFocus, isTrue);
              await tester.sendKeyEvent(LogicalKeyboardKey.tab);
              await tester.pumpAndSettle();
              await preview(
                tester,
                'jobs-modal-$language-${width.toInt()}-${scale.toInt()}x',
              );
              await tester.sendKeyEvent(LogicalKeyboardKey.enter);
              await tester.pumpAndSettle();
              expect(confirm, findsNothing);
              expect(fixture.mutations, hasLength(1));
              expect(jsonDecode(fixture.mutations.single.body), {
                'expectedRevision': 1,
              });
              const ActionDispatcher().invokeAction(
                oldKeyboard,
                const ActivateIntent(),
              );
              await tester.pumpAndSettle();
              expect(fixture.mutations, hasLength(1));
              expect(tester.takeException(), isNull);
            } finally {
              semantics.dispose();
            }
          },
        );
      }
    }
  }
  testWidgets(
    'busy history has no semantic tap and held View cannot dispatch',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final pending = Completer<http.Response>();
      try {
        await mount(tester);
        final view = key('job-view-${'a' * 32}');
        await visible(tester, view);
        final oldView = tester.widget<CupertinoButton>(view).onPressed!;
        final normal = fixture.respond!;
        fixture.respond = (request) => request.url.path.endsWith('/jobs')
            ? pending.future
            : normal(request);
        final refresh = key('jobs-refresh');
        Scrollable.of(tester.element(view)).position.jumpTo(0);
        await tester.pumpAndSettle();
        focus(tester, refresh).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pump();
        await tester.pump();
        expect(tester.widget<CupertinoButton>(view).onPressed, isNull);
        final node = action(tester, view);
        expect(node.flagsCollection.isEnabled, ui.Tristate.isFalse);
        expect(
          node.getSemanticsData().hasAction(ui.SemanticsAction.tap),
          isFalse,
        );
        final before = fixture.calls.length;
        node.owner!.performAction(node.id, ui.SemanticsAction.tap);
        oldView();
        await tester.pump();
        expect(fixture.calls.length, before);
        expect(key('job-refresh'), findsNothing);
        pending.complete(
          fixture.json({'jobs': fixture.records, 'nextBefore': null}),
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
  for (final retirement in ['route', 'idle']) {
    testWidgets(
      '$retirement before focus frame prevents stale Jobs scroll or GET',
      (tester) async {
        final interaction = AppInteractionController();
        addTearDown(interaction.dispose);
        await mount(tester, interaction: interaction);
        tester.view.physicalSize = const Size(600, 900);
        await tester.pumpAndSettle();
        final view = key('job-view-${'a' * 32}');
        await visible(tester, view);
        final position = Scrollable.of(tester.element(view)).position;
        final retained = tester.widget<CupertinoButton>(view).onPressed!;
        position.jumpTo(
          position.pixels +
              tester.getRect(view).top -
              tester.getRect(find.byType(CupertinoNavigationBar)).bottom,
        );
        await tester.pumpAndSettle();
        expect(
          tester.getRect(view).top - 3.5,
          lessThan(tester.getRect(find.byType(CupertinoNavigationBar)).bottom),
        );
        focus(tester, view).requestFocus();
        FocusManager.instance.applyFocusChangesIfNeeded();
        final offset = position.pixels, reads = fixture.calls.length;
        if (retirement == 'route') {
          unawaited(
            Navigator.of(tester.element(view)).push(
              CupertinoPageRoute<void>(
                builder: (_) =>
                    const CupertinoPageScaffold(child: Text('Covered')),
              ),
            ),
          );
        } else {
          interaction.setActive(false);
        }
        await tester.pumpAndSettle();
        expect(position.pixels, offset);
        retained();
        await tester.pumpAndSettle();
        expect(fixture.calls.length, reads);
        expect(fixture.mutations, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets('$retirement invalidates retained Jobs modal keyboard action', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final interaction = AppInteractionController();
      addTearDown(interaction.dispose);
      try {
        await mount(tester, interaction: interaction);
        await select(tester);
        final cancel = key('jobs-cancel');
        await visible(tester, cancel);
        focus(tester, cancel).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        final confirm = key('jobs-cancel-confirm');
        final detector = tester.widget<FocusableActionDetector>(
          find.descendant(
            of: confirm,
            matching: find.byType(FocusableActionDetector),
          ),
        );
        final retained = detector.actions![ActivateIntent]!;
        if (retirement == 'route') {
          unawaited(
            Navigator.of(tester.element(confirm)).push(
              CupertinoPageRoute<void>(
                builder: (_) =>
                    const CupertinoPageScaffold(child: Text('Covered')),
              ),
            ),
          );
        } else {
          interaction.setActive(false);
        }
        await tester.pumpAndSettle();
        final requests = fixture.calls.length;
        const ActionDispatcher().invokeAction(retained, const ActivateIntent());
        await tester.pumpAndSettle();
        expect(fixture.calls.length, requests);
        expect(fixture.mutations, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }
  testWidgets('visible detail toolbar forward reverse Tab preserves offset', (
    tester,
  ) async {
    await mount(tester, width: 1280, completed: true);
    await select(tester);
    final refresh = key('job-refresh'), cancel = key('jobs-history');
    final position = Scrollable.of(tester.element(refresh)).position;
    position.jumpTo(20);
    await tester.pumpAndSettle();
    final top = tester.getRect(find.byType(CupertinoNavigationBar)).bottom;
    for (final button in [refresh, cancel]) {
      final ring = tester.getRect(button).inflate(4);
      expect(ring.top, greaterThanOrEqualTo(top));
      expect(ring.bottom, lessThan(1000));
    }
    focus(tester, refresh).requestFocus();
    await tester.pumpAndSettle();
    expect(position.pixels, 20);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(focus(tester, cancel).hasPrimaryFocus, isTrue);
    expect(position.pixels, 20);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(focus(tester, refresh).hasPrimaryFocus, isTrue);
    expect(position.pixels, 20);
    expect(fixture.mutations, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    for (final width in [600.0, 1280.0]) {
      testWidgets(
        'real history Tab forward reverse keeps focus visible and contrasting $dark $width 2x',
        (tester) async {
          await mount(
            tester,
            language: dark ? 'tr' : 'en',
            width: width,
            dark: dark,
            safeInsets: width == 1280,
          );
          final refresh = key('jobs-refresh');
          await visible(tester, refresh);
          focus(tester, refresh).requestFocus();
          await tester.pump();
          Future<void> check(String id) async {
            final button = key('job-view-$id');
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
            expect(
              ring.top,
              greaterThanOrEqualTo(
                tester.getRect(find.byType(CupertinoNavigationBar)).bottom,
              ),
            );
            expect(
              ring.bottom,
              lessThanOrEqualTo(1000 - tester.view.padding.bottom),
            );
            expect(ring.left, greaterThanOrEqualTo(0));
            expect(ring.right, lessThanOrEqualTo(width));
            final background = CupertinoColors.secondarySystemGroupedBackground
                .resolveFrom(tester.element(button));
            final a = Color.alphaBlend(
                  side.color,
                  background,
                ).computeLuminance(),
                b = background.computeLuminance();
            expect(
              ((a > b ? a : b) + .05) / ((a < b ? a : b) + .05),
              greaterThanOrEqualTo(3),
            );
          }

          for (final record in fixture.records) {
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.pumpAndSettle();
            await check(record['id'] as String);
            if (record == fixture.records.first) {
              await preview(
                tester,
                'jobs-history-${dark ? 'tr-dark' : 'en-light'}-${width.toInt()}-2x',
              );
            }
          }
          for (final record in fixture.records.reversed.skip(1)) {
            await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
            await tester.pumpAndSettle();
            await check(record['id'] as String);
          }
          expect(fixture.mutations, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
