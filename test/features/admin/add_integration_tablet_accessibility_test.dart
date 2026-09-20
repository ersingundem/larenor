import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/admin/presentation/add_integration_screen.dart';
import 'package:larenor/features/admin/providers/admin_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/service_root_scaffold.dart';
import 'package:larenor/shared/widgets/settings_action_tile.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

import 'admin_test_fakes.dart';

Future<List<http.Request>> _mount(
  WidgetTester tester, {
  required String language,
  required double width,
  AddIntegrationScreen screen = const AddIntegrationScreen(),
  Future<http.Response> Function(http.Request request)? respond,
}) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final requests = <http.Request>[];
  final client = fakeAdminClient(
    RecordingAdminSocket(),
    respond: (request) async {
      requests.add(request);
      if (respond != null) return respond(request);
      if (request.url.path.endsWith('/flow_handlers')) {
        return http.Response(jsonEncode(['hue']), 200);
      }
      if (request.method == 'POST') {
        return http.Response(
          jsonEncode({
            'type': 'abort',
            'flow_id': 'flow-hue',
            'reason': 'finished',
          }),
          200,
        );
      }
      return http.Response('{}', 200);
    },
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [haAdminClientProvider.overrideWithValue(client)],
      child: CupertinoApp(
        locale: Locale(language),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: screen,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return requests;
}

void main() {
  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets(
        '$language integration picker is accessible at ${width}px 2x',
        (tester) async {
          final semantics = tester.ensureSemantics();
          await _mount(tester, language: language, width: width);

          expect(find.byType(ServiceRootScaffold), findsOneWidget);
          expect(find.byType(SettingsSection), findsOneWidget);
          expect(find.byType(SettingsActionTile), findsOneWidget);
          expect(
            tester
                .getSemantics(
                  find.byKey(const ValueKey('integration-list-header')),
                )
                .flagsCollection
                .isHeader,
            isTrue,
          );

          final handler = find.byKey(const ValueKey('integration-handler-hue'));
          expect(tester.getRect(handler).height, greaterThanOrEqualTo(48));
          expect(tester.getSemantics(handler).flagsCollection.isButton, isTrue);

          Focus.of(
            tester.element(
              find.descendant(of: handler, matching: find.text('hue')),
            ),
          ).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();

          expect(find.text('finished'), findsOneWidget);
          expect(tester.takeException(), isNull);
          semantics.dispose();
        },
      );
    }
  }

  testWidgets('handler failure retries into the accessible picker', (
    tester,
  ) async {
    var attempts = 0;
    await _mount(
      tester,
      language: 'en',
      width: 600,
      respond: (request) async {
        attempts++;
        if (attempts == 1) return http.Response('unavailable', 503);
        return http.Response(jsonEncode(['hue']), 200);
      },
    );

    final retry = tester.widget<CupertinoButton>(
      find.widgetWithText(CupertinoButton, 'Retry'),
    );
    expect(retry.minimumSize?.height, greaterThanOrEqualTo(48));
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('integration-handler-hue')),
      findsOneWidget,
    );
    expect(attempts, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('menu choice supports Enter and reaches the result', (
    tester,
  ) async {
    var posts = 0;
    await _mount(
      tester,
      language: 'en',
      width: 600,
      screen: const AddIntegrationScreen(handler: 'hue'),
      respond: (request) async {
        posts++;
        return http.Response(
          jsonEncode(
            posts == 1
                ? {
                    'type': 'menu',
                    'flow_id': 'flow-hue',
                    'step_id': 'choose',
                    'title': 'Choose setup',
                    'menu_options': ['manual'],
                  }
                : {
                    'type': 'create_entry',
                    'flow_id': 'flow-hue',
                    'step_id': 'finish',
                  },
          ),
          200,
        );
      },
    );

    final choice = find.byKey(const ValueKey('integration-menu-manual'));
    expect(tester.getRect(choice).height, greaterThanOrEqualTo(48));
    expect(tester.getSemantics(choice).flagsCollection.isButton, isTrue);
    Focus.of(
      tester.element(
        find.descendant(of: choice, matching: find.text('manual')),
      ),
    ).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(posts, 2);
    expect(find.byIcon(CupertinoIcons.check_mark_circled), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('progress polling reaches a completed setup without retry', (
    tester,
  ) async {
    final requests = await _mount(
      tester,
      language: 'en',
      width: 600,
      screen: const AddIntegrationScreen(handler: 'hue'),
      respond: (request) async => http.Response(
        jsonEncode(
          request.method == 'POST'
              ? {
                  'type': 'progress',
                  'flow_id': 'flow-hue',
                  'step_id': 'install',
                }
              : {
                  'type': 'create_entry',
                  'flow_id': 'flow-hue',
                  'step_id': 'finish',
                },
        ),
        200,
      ),
    );

    expect(requests.map((request) => request.method), ['POST', 'GET']);
    expect(find.byIcon(CupertinoIcons.check_mark_circled), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('captured integration action expires after lifecycle return', (
    tester,
  ) async {
    final requests = await _mount(tester, language: 'en', width: 600);
    final old = tester
        .widget<CupertinoButton>(
          find.byKey(const ValueKey('integration-handler-hue')),
        )
        .onPressed!;
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    old();
    await tester.pumpAndSettle();
    expect(requests.map((request) => request.method), ['GET']);
    expect(find.textContaining('app session changed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
