import 'dart:async';
import 'dart:convert' show jsonDecode;
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
        path.endsWith('/jobs/${records.first['id']}/cancel'))
      records[0] = job;
    return response;
  }
}

void main() {
  late _JobsFixture fixture;
  Future<void> mount(
    WidgetTester tester, {
    String language = 'en',
    double width = 600,
    bool dark = false,
    bool completed = false,
    double scale = 2,
  }) async {
    await loadFonts(tester);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'settings_pin': '1234'});
    fixture = _JobsFixture()..configured = false;
    if (completed)
      fixture.records[0] = pluginJobJson(state: 'succeeded', revision: 3);
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
          locale: Locale(language),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
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
    if (target.evaluate().isEmpty)
      await tester.scrollUntilVisible(
        target,
        300,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 30,
      );
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
              expect(node.rect.height, greaterThanOrEqualTo(48));
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
                final matching = nodes.where((n) => !n.isMergedIntoParent && n.getSemanticsData().label == label).toList();
                expect(matching, hasLength(1));
                final node = matching.single;
                expect(node.getSemanticsData().flagsCollection.isButton, isTrue);
                expect(
                  node.getSemanticsData().hasAction(ui.SemanticsAction.tap),
                  isTrue,
                );
                expect(node.rect.width, greaterThanOrEqualTo(48));
                expect(node.rect.height, greaterThanOrEqualTo(48));
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
              await tester.sendKeyEvent(LogicalKeyboardKey.enter);
              await tester.pumpAndSettle();
              expect(confirm, findsNothing);
              expect(fixture.mutations, hasLength(1));
              expect(jsonDecode(fixture.mutations.single.body), {
                'expectedRevision': 1,
              });
              oldKeyboard.invoke(const ActivateIntent());
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
            expect(ring.bottom, lessThanOrEqualTo(1000));
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
