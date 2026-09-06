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
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/features/server/services/presentation/server_services_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import '../../support/restore_dialog_geometry.dart';
import '../home_resources/home_resources_tablet_test.dart' show loadFonts;
import 'server_services_test.dart';

const _otherId = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';

/// Existing actual account/HTTP fixture, extended only for two distinct rows.
class _ServicesFixture extends ServicesFixture {
  @override
  http.Response serviceResponse(http.Request request) {
    if (request.method == 'DELETE') {
      final matches = records.where(
        (record) => request.url.path.endsWith('/services/${record['id']}'),
      );
      if (matches.length != 1 ||
          request.url.queryParameters.length != 1 ||
          request.url.queryParameters['expectedRevision'] !=
              '${matches.single['revision']}') {
        return json({'error': {'code': 'revision_conflict'}}, 409);
      }
      records.remove(matches.single);
      return http.Response('', 204);
    }
    return super.serviceResponse(request);
  }
}

void main() {
  late _ServicesFixture fixture;
  late GlobalKey boundary;

  Future<void> mount(
    WidgetTester tester, {
    String language = 'en',
    double width = 600,
    double scale = 2,
    bool dark = false,
    bool safeInsets = false,
    AppInteractionController? interaction,
  }) async {
    await loadFonts(tester);
    boundary = GlobalKey();
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'settings_pin': '1234'});
    fixture = _ServicesFixture()
      ..records.addAll([
        serviceJson(),
        {
          ...serviceJson(state: 'reachable'),
          'id': _otherId,
          'name': 'Çalışma odası müzik',
          'baseUrl': 'https://music.example.test',
          'credentialKeys': <String>[],
        },
      ]);
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
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
            ),
            child: RepaintBoundary(
              key: boundary,
              child: interaction == null
                  ? child!
                  : AppInteractionScope(controller: interaction, child: child!),
            ),
          ),
          home: const ServerServicesScreen(),
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
  FocusNode focus(WidgetTester tester, Finder button) =>
      Focus.of(tester.element(caption(button)));
  List<SemanticsNode> nodes(WidgetTester tester, Finder target) {
    final result = <SemanticsNode>[];
    void visit(SemanticsNode node) {
      if (!node.isMergedIntoParent) result.add(node);
      node.visitChildren((child) {
        visit(child);
        return true;
      });
    }
    visit(tester.getSemantics(target).owner!.rootSemanticsNode!);
    return result;
  }

  Future<void> visible(WidgetTester tester, Finder target) async {
    if (target.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        target,
        300,
        scrollable: find.byWidgetPredicate(
          (widget) => widget is Scrollable &&
              axisDirectionToAxis(widget.axisDirection) == Axis.vertical,
        ).first,
        maxScrolls: 20,
      );
    }
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder target) async {
    await visible(tester, target);
    expect(target.hitTestable(), findsOneWidget);
    await tester.tap(target.hitTestable());
    await tester.pumpAndSettle();
  }

  Future<void> reverseTab(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
  }

  List<Color> backgrounds(WidgetTester tester, Finder button) {
    List<Color>? result;
    tester.element(caption(button)).visitAncestorElements((element) {
      if (element.widget case DecoratedBox(decoration: final BoxDecoration box)) {
        if (box.gradient case final LinearGradient gradient) {
          result = gradient.colors;
          return false;
        }
        if (box.color case final Color color when color.a == 1) {
          result = [color];
          return false;
        }
      }
      return true;
    });
    expect(result, isNotNull, reason: 'measure the actual card or page surface');
    return result!;
  }

  Future<double> paintedFocusContrast(WidgetTester tester, Finder button) async {
    final render = boundary.currentContext!.findRenderObject()!
        as RenderRepaintBoundary;
    final rect = tester.getRect(button).shift(-render.localToGlobal(Offset.zero));
    return tester.runAsync(() async {
      final image = await render.toImage(pixelRatio: 1);
      try {
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
        Color pixel(double y) {
          final i = (y.floor() * image.width + rect.center.dx.floor()) * 4;
          return Color.fromARGB(bytes.getUint8(i + 3), bytes.getUint8(i),
              bytes.getUint8(i + 1), bytes.getUint8(i + 2));
        }
        // Native outline paints 3.5px outside the top edge. Compare it with
        // the adjacent actual translucent popup surface, not an assumed color.
        final a = pixel(rect.top - 2).computeLuminance();
        final b = pixel(rect.top - 6).computeLuminance();
        return ((a > b ? a : b) + .05) / ((a < b ? a : b) + .05);
      } finally {
        image.dispose();
      }
    }).then((value) => value!);
  }

  Future<void> preview(WidgetTester tester, String name) async {
    const directory = String.fromEnvironment('SERVICES_TABLET_PREVIEW_DIR');
    if (directory.isEmpty) return;
    await tester.runAsync(() async {
      final render = boundary.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 1);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(directory).create(recursive: true);
        await File('$directory/$name.png').writeAsBytes(
          data!.buffer.asUint8List(),
        );
      } finally {
        image.dispose();
      }
    });
  }

  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1280.0]) {
      testWidgets('two service headings stay separate $language $width 2x', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        try {
          await mount(tester, language: language, width: width);
          for (final record in fixture.records) {
            final title = find.text(record['name'] as String);
            await visible(tester, title);
            final effective = nodes(tester, title).where((node) {
              final data = node.getSemanticsData();
              return data.flagsCollection.isHeader && data.label == record['name'];
            }).toList();
            expect(effective, hasLength(1),
                reason: 'only the exact connection name is a heading');
            final data = effective.single.getSemanticsData();
            expect(data.flagsCollection.isHeader, isTrue);
            expect(data.flagsCollection.isButton, isFalse);
          }
          expect(fixture.mutations, isEmpty);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });

      testWidgets('service actions name their connection once $language $width 2x', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        try {
          await mount(tester, language: language, width: width);
          final l10n = AppLocalizations.of(tester.element(key('services-add')));
          for (final record in fixture.records) {
            for (final entry in {
              'check': l10n.serverServicesCheck,
              'edit': l10n.commonEdit,
              'forget': l10n.serverServicesForget,
            }.entries) {
              final button = key('service-${entry.key}-${record['id']}');
              await visible(tester, button);
              final matches = nodes(tester, caption(button)).where((node) {
                final data = node.getSemanticsData();
                return data.flagsCollection.isButton &&
                    data.label.contains(record['name'] as String) &&
                    data.label.contains(entry.value);
              }).toList();
              expect(matches, hasLength(1));
              final data = matches.single.getSemanticsData();
              expect(data.flagsCollection.isHeader, isFalse);
              expect(data.hasAction(ui.SemanticsAction.tap), isTrue);
              expect(matches.single.rect.width, greaterThanOrEqualTo(48));
              expect(matches.single.rect.height, greaterThanOrEqualTo(48));
            }
          }
          expect(fixture.mutations, isEmpty);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });

      testWidgets('forget modal real Tab reverse Enter and Space $language $width 2x', (
        tester,
      ) async {
        await mount(tester, language: language, width: width);
        final open = key('service-forget-$serviceId');
        await tap(tester, open);
        final l10n = AppLocalizations.of(tester.element(key('service-confirm-forget')));
        final cancel = find.widgetWithText(CupertinoDialogAction, l10n.commonCancel);
        final confirm = key('service-confirm-forget');
        // Reach the actual modal action using hardware traversal. A missing
        // focus ancestor is an unusable action, not a fixture exception.
        for (var i = 0; i < 8; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pumpAndSettle();
          if (Focus.maybeOf(tester.element(caption(cancel)))?.hasPrimaryFocus == true) break;
        }
        expect(Focus.maybeOf(tester.element(caption(cancel)))?.hasPrimaryFocus,
            isTrue, reason: 'Tab must reach Cancel in the actual modal');
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        expect(focus(tester, confirm).hasPrimaryFocus, isTrue);
        await reverseTab(tester);
        expect(focus(tester, cancel).hasPrimaryFocus, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.byType(CupertinoAlertDialog), findsNothing);
        expect(fixture.mutations, isEmpty);
        expect(fixture.records, hasLength(2));
        await tap(tester, open);
        focus(tester, key('service-confirm-forget')).requestFocus();
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
        expect(fixture.mutations, hasLength(1));
        final request = fixture.mutations.single;
        expect(request.method, 'DELETE');
        expect(request.url.path, endsWith('/services/$serviceId'));
        expect(request.url.queryParameters, {'expectedRevision': '1'});
        expect(fixture.records.single['id'], _otherId);
        expect(tester.takeException(), isNull);
      });

      testWidgets('form keyboard footer has painted focus $language $width 2x', (tester) async {
        await mount(tester, language: language, width: width, dark: language == 'tr');
        await tap(tester, key('services-add'));
        final token = key('service-credential-token');
        await visible(tester, token);
        await tester.enterText(token, 'synthetic-tablet-secret');
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        final l10n = AppLocalizations.of(tester.element(key('service-submit')));
        final cancel = find.widgetWithText(CupertinoButton, l10n.commonCancel);
        expect(focus(tester, cancel).hasPrimaryFocus, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        expect(focus(tester, key('service-submit')).hasPrimaryFocus, isTrue);
        await reverseTab(tester);
        expect(focus(tester, cancel).hasPrimaryFocus, isTrue);
        expect(await paintedFocusContrast(tester, cancel), greaterThanOrEqualTo(3));
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(key('service-submit'), findsNothing);
        expect(fixture.mutations, isEmpty);
        expect(tester.takeException(), isNull);
      });

      testWidgets('form input Next advances only once $language $width 2x', (tester) async {
        await mount(tester, language: language, width: width);
        await tap(tester, key('services-add'));
        final token = key('service-credential-token');
        await visible(tester, token);
        await tester.enterText(token, 'synthetic-tablet-secret');
        await tester.testTextInput.receiveAction(TextInputAction.next);
        await tester.pumpAndSettle();
        final l10n = AppLocalizations.of(tester.element(key('service-submit')));
        final cancel = find.widgetWithText(CupertinoButton, l10n.commonCancel);
        expect(focus(tester, cancel).hasPrimaryFocus, isTrue,
            reason: 'Next must move once; Save focused: '
                '${focus(tester, key('service-submit')).hasPrimaryFocus}');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(key('service-submit'), findsNothing);
        expect(fixture.mutations, isEmpty);
      });

      for (final scale in [1.0, 2.0]) {
        testWidgets('forget effective button geometry $language $width ${scale}x', (
          tester,
        ) async {
          final semantics = tester.ensureSemantics();
          try {
            await mount(tester, language: language, width: width,
                scale: scale, dark: language == 'tr');
            await tap(tester, key('service-forget-$serviceId'));
            final confirm = key('service-confirm-forget');
            final l10n = AppLocalizations.of(tester.element(confirm));
            final cancel = find.widgetWithText(CupertinoDialogAction, l10n.commonCancel);
            final failures = restoreDialogGeometryFailures(tester,
              labels: [l10n.commonCancel, l10n.serverServicesForget], cancel: cancel);
            expect(failures, isEmpty);
            focus(tester, cancel).requestFocus();
            await tester.pumpAndSettle();
            await preview(tester, 'services-modal-$language-${width.toInt()}-${scale.toInt()}x');
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pumpAndSettle();
            expect(find.byType(CupertinoAlertDialog), findsNothing);
            expect(fixture.mutations, isEmpty);
          } finally {
            semantics.dispose();
          }
        });

        testWidgets('form labeled fields fit native targets $language $width ${scale}x', (
          tester,
        ) async {
          final semantics = tester.ensureSemantics();
          try {
            await mount(tester, language: language, width: width,
                scale: scale, dark: language == 'tr');
            await tap(tester, key('services-add'));
            final l10n = AppLocalizations.of(tester.element(key('service-submit')));
            final failures = <String>[];
            for (final field in {
              'service-name': l10n.serverServicesName,
              'service-url': l10n.serverUrl,
              'service-credential-token': l10n.serverServicesToken,
            }.entries) {
              final target = key(field.key);
              await visible(tester, target);
              final matching = nodes(tester, target).where((n) {
                final data = n.getSemanticsData();
                return data.flagsCollection.isTextField && data.label == field.value;
              }).toList();
              expect(matching, hasLength(1));
              if (matching.single.rect.width < 48 || matching.single.rect.height < 48) {
                failures.add('${field.key}: ${matching.single.rect.size}');
              }
              final input = tester.widget<CupertinoTextField>(target);
              expect(input.autocorrect, isFalse);
              expect(input.enableSuggestions, isFalse);
              expect(input.textInputAction, TextInputAction.next);
            }
            expect(failures, isEmpty);
            final token = key('service-credential-token');
            await tester.enterText(token, 'synthetic-tablet-secret');
            await tester.pump();
            expect(tester.widget<CupertinoTextField>(token).obscureText, isTrue);
            expect(tester.widgetList<Text>(find.byType(Text))
                .map((text) => text.data ?? '').join(' '),
                isNot(contains('synthetic-tablet-secret')));
            final cancel = find.widgetWithText(CupertinoButton, l10n.commonCancel);
            await visible(tester, cancel);
            focus(tester, cancel).requestFocus();
            await tester.pumpAndSettle();
            await preview(tester, 'services-form-$language-${width.toInt()}-${scale.toInt()}x');
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pumpAndSettle();
            expect(key('service-submit'), findsNothing);
            expect(fixture.mutations, isEmpty);
            expect(tester.takeException(), isNull);
          } finally {
            semantics.dispose();
          }
        });
      }
    }
  }

  for (final dark in [false, true]) {
    for (final width in [600.0, 1280.0]) {
      testWidgets('native Tab viewport and contrast $dark $width 2x', (tester) async {
        await mount(tester, language: dark ? 'tr' : 'en', width: width,
            dark: dark, safeInsets: width == 1280);
        final add = key('services-add');
        focus(tester, add).requestFocus();
        await tester.pumpAndSettle();
        final order = ['services-refresh', for (final record in fixture.records)
          for (final action in ['check', 'edit', 'forget'])
            'service-$action-${record['id']}'];
        void check(String id) {
          final button = key(id);
          expect(focus(tester, button).hasPrimaryFocus, isTrue);
          final decorations = find.descendant(of: button,
            matching: find.byWidgetPredicate((widget) => widget is DecoratedBox &&
              widget.decoration is ShapeDecoration &&
              (widget.decoration as ShapeDecoration).shape is OutlinedBorder));
          final side = ((tester.widget<DecoratedBox>(decorations.first).decoration
            as ShapeDecoration).shape as OutlinedBorder).side;
          expect(side.width, greaterThan(0));
          final ring = tester.getRect(button).inflate(side.width);
          expect(ring.top, greaterThanOrEqualTo(tester.getRect(find.byType(CupertinoNavigationBar)).bottom));
          expect(ring.bottom, lessThanOrEqualTo(1000 - tester.view.padding.bottom));
          expect(ring.left, greaterThanOrEqualTo(0));
          expect(ring.right, lessThanOrEqualTo(width));
          for (final background in backgrounds(tester, button)) {
            final a = Color.alphaBlend(side.color, background).computeLuminance();
            final b = background.computeLuminance();
            expect(((a > b ? a : b) + .05) / ((a < b ? a : b) + .05), greaterThanOrEqualTo(3));
          }
        }
        for (final id in order) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pumpAndSettle();
          check(id);
          if (id == 'service-check-$serviceId') {
            await preview(tester, 'services-list-${dark ? 'tr-dark' : 'en-light'}-${width.toInt()}-2x');
          }
        }
        for (final id in order.reversed.skip(1)) {
          await reverseTab(tester);
          check(id);
        }
        expect(fixture.mutations, isEmpty);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
