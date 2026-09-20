import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/ha_client/data/rest_client.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/ha_tools/presentation/ha_tools_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/app_page_scaffold.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

Widget app(
  HaTool tool,
  HaRestClient client, {
  Locale locale = const Locale('en'),
  double textScale = 1,
  ConnectionConfig Function()? connection,
}) => ProviderScope(
  overrides: [
    if (connection != null) connectionConfigProvider.overrideWith(connection),
    haRestClientProvider.overrideWith((ref) => client),
  ],
  child: CupertinoApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: connection == null
        ? HaToolScreen(tool: tool)
        : Consumer(
            builder: (context, ref, _) {
              final configured = ref.watch(connectionConfigProvider);
              return configured.isLoading
                  ? const CupertinoPageScaffold(
                      child: CupertinoActivityIndicator(),
                    )
                  : HaToolScreen(tool: tool);
            },
          ),
  ),
);

class _Connection extends ConnectionConfig {
  @override
  Future<HaConnectionConfig?> build() async => const HaConnectionConfig(
    baseUrl: 'http://ha.test',
    token: 'synthetic-token',
  );

  void rotate() => state = const AsyncData(
    HaConnectionConfig(
      baseUrl: 'http://new-ha.test',
      token: 'new-synthetic-token',
    ),
  );
}

Future<void> tabTo(WidgetTester tester, Key key) async {
  for (var index = 0; index < 16; index++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final button = FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<CupertinoButton>();
    if (button?.key == key) return;
  }
  fail('The requested HA tool action is not keyboard reachable.');
}

void main() {
  testWidgets(
    'missing optional calendar integration is explained without failure',
    (tester) async {
      final requests = <http.Request>[];
      final client = HaRestClient(
        baseUrl: 'http://ha.test',
        token: 'test',
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response('not found', 404);
        }),
      );
      addTearDown(client.dispose);
      await tester.pumpWidget(app(HaTool.calendars, client));
      await tester.pumpAndSettle();
      expect(requests, isEmpty);
      await tester.tap(find.widgetWithText(CupertinoButton, 'Read'));
      await tester.pumpAndSettle();
      expect(requests.single.method, 'GET');
      expect(
        find.textContaining('This endpoint is unavailable'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('history invalid range makes no request', (tester) async {
    var requests = 0;
    final client = HaRestClient(
      baseUrl: 'http://ha.test',
      token: 'test',
      httpClient: MockClient((request) async {
        requests++;
        return http.Response('[]', 200);
      }),
    );
    addTearDown(client.dispose);
    await tester.pumpWidget(app(HaTool.history, client));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(CupertinoTextField).at(1), 'not-a-date');
    await tester.tap(find.widgetWithText(CupertinoButton, 'Read'));
    await tester.pumpAndSettle();
    expect(requests, 0);
    expect(find.textContaining('Enter valid ISO'), findsOneWidget);
  });

  testWidgets(
    'transport failures hide backend details and announce a safe error',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final client = HaRestClient(
        baseUrl: 'http://ha.test',
        token: 'test',
        httpClient: MockClient((request) async {
          throw StateError(
            'Bearer private-token at http://internal.home/api/config',
          );
        }),
      );
      addTearDown(client.dispose);
      try {
        await tester.pumpWidget(app(HaTool.server, client));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(CupertinoButton, 'Read'));
        await tester.pumpAndSettle();
        expect(find.text('The request could not be completed'), findsOneWidget);
        expect(find.textContaining('private-token'), findsNothing);
        expect(find.textContaining('internal.home'), findsNothing);
        expect(
          tester
              .getSemantics(find.byKey(const ValueKey('ha-result-live-region')))
              .flagsCollection
              .isLiveRegion,
          isTrue,
        );
      } finally {
        semantics.dispose();
      }
    },
  );

  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1200.0]) {
      testWidgets(
        '${locale.languageCode} live subscription is a 48dp keyboard and TalkBack toggle at ${width.toInt()}px',
        (tester) async {
          final semantics = tester.ensureSemantics();
          final client = HaRestClient(
            baseUrl: 'http://ha.test',
            token: 'test',
            httpClient: MockClient((request) async => http.Response('[]', 200)),
          );
          addTearDown(client.dispose);
          tester.view.physicalSize = Size(width, 1100);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          try {
            await tester.pumpWidget(
              app(HaTool.events, client, locale: locale, textScale: 2),
            );
            await tester.pumpAndSettle();
            final l10n = await AppLocalizations.delegate.load(locale);
            final toggle = find.byKey(const ValueKey('ha-live-toggle'));
            expect(tester.getRect(toggle).height, greaterThanOrEqualTo(48));
            final node = tester.getSemantics(toggle);
            expect(node.label, l10n.haLive);
            expect(node.flagsCollection.isToggled, ui.Tristate.isFalse);
            await tabTo(tester, const ValueKey('ha-live-toggle'));
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pump();
            expect(
              tester.getSemantics(toggle).flagsCollection.isToggled,
              ui.Tristate.isTrue,
            );
            expect(tester.takeException(), isNull);
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }

  testWidgets('console cannot send credentials to another server', (
    tester,
  ) async {
    var requests = 0;
    final client = HaRestClient(
      baseUrl: 'http://ha.test',
      token: 'test',
      httpClient: MockClient((request) async {
        requests++;
        return http.Response('{}', 200);
      }),
    );
    addTearDown(client.dispose);
    await tester.pumpWidget(app(HaTool.api, client));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(CupertinoTextField).first,
      'https://another.example/api/config',
    );
    await tester.ensureVisible(find.widgetWithText(CupertinoButton, 'Run'));
    await tester.tap(find.widgetWithText(CupertinoButton, 'Run'));
    await tester.pumpAndSettle();
    expect(requests, 0);
    expect(find.textContaining('valid value'), findsOneWidget);
  });

  for (final invalidation in ['account', 'background', 'route']) {
    testWidgets(
      '$invalidation change rejects an in-flight result and expires old actions',
      (tester) async {
        final response = Completer<http.Response>();
        var requests = 0;
        final client = HaRestClient(
          baseUrl: 'http://ha.test',
          token: 'test',
          httpClient: MockClient((request) {
            requests++;
            return response.future;
          }),
        );
        addTearDown(client.dispose);
        await tester.pumpWidget(
          app(HaTool.api, client, connection: _Connection.new),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(CupertinoButton, 'Run'));
        await tester.pump();
        expect(requests, 1);

        if (invalidation == 'account') {
          final container = ProviderScope.containerOf(
            tester.element(find.byType(HaToolScreen)),
          );
          (container.read(connectionConfigProvider.notifier) as _Connection)
              .rotate();
          await tester.pump();
        } else if (invalidation == 'background') {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
          await tester.pump();
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await tester.pump();
        } else {
          final context = tester.element(find.byType(HaToolScreen));
          final navigator = Navigator.of(context);
          unawaited(
            navigator.push<void>(
              CupertinoPageRoute(
                builder: (_) =>
                    const CupertinoPageScaffold(child: Text('Covering route')),
              ),
            ),
          );
          await tester.pumpAndSettle();
          navigator.pop();
          await tester.pumpAndSettle();
        }

        response.complete(http.Response('{"private":"old-account"}', 200));
        await tester.pumpAndSettle();
        expect(find.textContaining('old-account'), findsNothing);
        expect(
          tester
              .widget<CupertinoButton>(
                find.byKey(const ValueKey('ha-primary-action')),
              )
              .onPressed,
          isNull,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1200.0]) {
      testWidgets(
        '${locale.languageCode} API console fits ${width.toInt()}px at 2x text and keeps keyboard semantics',
        (tester) async {
          final semantics = tester.ensureSemantics();
          final requests = <http.Request>[];
          final client = HaRestClient(
            baseUrl: 'http://ha.test',
            token: 'test',
            httpClient: MockClient((request) async {
              requests.add(request);
              return http.Response('{}', 200);
            }),
          );
          addTearDown(client.dispose);
          tester.view.physicalSize = Size(width, 1100);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          try {
            await tester.pumpWidget(
              app(HaTool.api, client, locale: locale, textScale: 2),
            );
            await tester.pumpAndSettle();
            final l10n = await AppLocalizations.delegate.load(locale);
            expect(find.byType(AppPageScaffold), findsOneWidget);
            expect(find.byType(SettingsSection), findsOneWidget);
            final requestHeading = find.byKey(
              const ValueKey('ha-request-heading'),
            );
            expect(
              tester.getSemantics(requestHeading).flagsCollection.isHeader,
              isTrue,
            );
            expect(
              tester
                  .getRect(find.byKey(const ValueKey('ha-protocol-control')))
                  .height,
              greaterThanOrEqualTo(48),
            );
            final run = find.widgetWithText(CupertinoButton, l10n.haRun);
            await tester.ensureVisible(run);
            final runButton = tester.widget<CupertinoButton>(run);
            expect(runButton.minimumSize?.height, greaterThanOrEqualTo(48));
            await tabTo(tester, const ValueKey('ha-primary-action'));
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pumpAndSettle();
            expect(requests, hasLength(1));
            expect(find.byType(SettingsSection), findsNWidgets(2));
            final resultHeading = find.byKey(
              const ValueKey('ha-result-heading'),
            );
            expect(
              tester.getSemantics(resultHeading).flagsCollection.isHeader,
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
}
