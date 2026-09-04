import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/ha_client/data/rest_client.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/ha_tools/presentation/ha_tools_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

Widget app(HaTool tool, HaRestClient client) => ProviderScope(
  overrides: [haRestClientProvider.overrideWith((ref) => client)],
  child: CupertinoApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: HaToolScreen(tool: tool),
  ),
);

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
    expect(find.textContaining('relative Home Assistant'), findsOneWidget);
  });
}
