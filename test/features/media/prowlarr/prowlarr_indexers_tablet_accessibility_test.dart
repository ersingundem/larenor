import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/direct_home_access.dart';
import 'package:larenor/features/media/prowlarr/data/models/prowlarr_indexer.dart';
import 'package:larenor/features/media/prowlarr/data/prowlarr_client.dart';
import 'package:larenor/features/media/prowlarr/data/prowlarr_config.dart';
import 'package:larenor/features/media/prowlarr/presentation/prowlarr_indexers_screen.dart';
import 'package:larenor/features/media/prowlarr/providers/prowlarr_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/app_page_scaffold.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

const _config = ProwlarrConfig(
  baseUrl: 'http://127.0.0.1:9696',
  apiKey: 'fixture',
);

const _indexer = ProwlarrIndexer(
  id: 3,
  name: 'Local Indexer',
  enabled: true,
  protocol: 'torrent',
  priority: 25,
  raw: {
    'id': 3,
    'name': 'Local Indexer',
    'enable': true,
    'protocol': 'torrent',
    'priority': 25,
  },
);

final _currentProwlarrClient =
    NotifierProvider<_CurrentProwlarrClient, ProwlarrClient?>(
      _CurrentProwlarrClient.new,
    );
ProwlarrClient? _initialProwlarrClient;

class _CurrentProwlarrClient extends Notifier<ProwlarrClient?> {
  @override
  ProwlarrClient? build() => _initialProwlarrClient;

  void replace(ProwlarrClient value) => state = value;
}

class _Connection extends ProwlarrConnection {
  @override
  Future<ProwlarrConfig?> build() async {
    ref.watch(directHomeAccessProvider);
    return _config;
  }
}

Widget _tabletApp(Locale locale) => CupertinoApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context)
        .copyWith(textScaler: const TextScaler.linear(2)),
    child: child!,
  ),
  home: const ProwlarrIndexersScreen(),
);

Future<void> _tabToToggle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    if (FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<CupertinoSwitch>() !=
        null) {
      return;
    }
  }
  fail('The Prowlarr indexer toggle is not reachable with Tab.');
}

void main() {
  testWidgets('captured indexer toggle cannot cross Prowlarr authority', (
    tester,
  ) async {
    final oldRequests = <http.Request>[];
    final replacementRequests = <http.Request>[];
    ProwlarrClient client(List<http.Request> requests) => ProwlarrClient(
      config: _config,
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response('{}', 200);
      }),
    );
    final oldClient = client(oldRequests);
    final replacementClient = client(replacementRequests);
    addTearDown(oldClient.dispose);
    addTearDown(replacementClient.dispose);
    _initialProwlarrClient = oldClient;
    addTearDown(() => _initialProwlarrClient = null);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prowlarrConnectionProvider.overrideWith(_Connection.new),
          prowlarrClientProvider.overrideWith(
            (ref) => ref.watch(_currentProwlarrClient),
          ),
          prowlarrIndexersProvider.overrideWith((_) async => const [_indexer]),
        ],
        child: _tabletApp(const Locale('en')),
      ),
    );
    await tester.pumpAndSettle();
    final toggle = tester
        .widget<CupertinoSwitch>(find.byType(CupertinoSwitch))
        .onChanged!;
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProwlarrIndexersScreen)),
    );
    container.read(_currentProwlarrClient.notifier).replace(replacementClient);
    await tester.pumpAndSettle();

    toggle(false);
    await tester.pumpAndSettle();

    expect(oldRequests, isEmpty);
    expect(replacementRequests, isEmpty);
  });

  testWidgets('indexer reload hides retained toggle and expires callback', (
    tester,
  ) async {
    final requests = <http.Request>[];
    final client = ProwlarrClient(
      config: _config,
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response('{}', 200);
      }),
    );
    addTearDown(client.dispose);
    var reads = 0;
    final reload = Completer<List<ProwlarrIndexer>>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prowlarrConnectionProvider.overrideWith(_Connection.new),
          prowlarrClientProvider.overrideWith((_) => client),
          prowlarrIndexersProvider.overrideWith((_) {
            reads++;
            return reads == 1 ? Future.value(const [_indexer]) : reload.future;
          }),
        ],
        child: _tabletApp(const Locale('en')),
      ),
    );
    await tester.pumpAndSettle();
    final old = tester
        .widget<CupertinoSwitch>(find.byType(CupertinoSwitch))
        .onChanged!;
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProwlarrIndexersScreen)),
    );
    container.invalidate(prowlarrIndexersProvider);
    await tester.pump();

    expect(find.text('Local Indexer'), findsNothing);
    old(false);
    await tester.pump();
    expect(requests, isEmpty);

    reload.complete(const [_indexer]);
    await tester.pumpAndSettle();
    expect(find.text('Local Indexer'), findsOneWidget);
  });

  testWidgets('older toggle completion cannot unlock replacement write', (
    tester,
  ) async {
    final oldResponse = Completer<http.Response>();
    final newResponse = Completer<http.Response>();
    ProwlarrClient client(Completer<http.Response> response) => ProwlarrClient(
      config: _config,
      httpClient: MockClient((_) => response.future),
    );
    final oldClient = client(oldResponse);
    final newClient = client(newResponse);
    addTearDown(oldClient.dispose);
    addTearDown(newClient.dispose);
    _initialProwlarrClient = oldClient;
    addTearDown(() => _initialProwlarrClient = null);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prowlarrConnectionProvider.overrideWith(_Connection.new),
          prowlarrClientProvider.overrideWith(
            (ref) => ref.watch(_currentProwlarrClient),
          ),
          prowlarrIndexersProvider.overrideWith((_) async => const [_indexer]),
        ],
        child: _tabletApp(const Locale('en')),
      ),
    );
    await tester.pumpAndSettle();
    CupertinoSwitch toggle() =>
        tester.widget<CupertinoSwitch>(find.byType(CupertinoSwitch));
    toggle().onChanged!(false);
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProwlarrIndexersScreen)),
    );
    container.read(_currentProwlarrClient.notifier).replace(newClient);
    await tester.pump();
    toggle().onChanged!(false);
    await tester.pump();

    oldResponse.complete(http.Response('{}', 200));
    await tester.pump();
    expect(toggle().onChanged, isNull);

    newResponse.complete(http.Response('{}', 200));
    await tester.pumpAndSettle();
    expect(toggle().onChanged, isNotNull);
  });

  testWidgets('failed indexer write announces only localized safe copy', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final client = ProwlarrClient(
      config: _config,
      httpClient: MockClient(
        (_) async => http.Response('private upstream detail', 500),
      ),
    );
    addTearDown(client.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prowlarrConnectionProvider.overrideWith(_Connection.new),
          prowlarrClientProvider.overrideWith((_) => client),
          prowlarrIndexersProvider.overrideWith((_) async => const [_indexer]),
        ],
        child: _tabletApp(const Locale('tr')),
      ),
    );
    await tester.pumpAndSettle();

    tester.widget<CupertinoSwitch>(find.byType(CupertinoSwitch)).onChanged!(
      false,
    );
    await tester.pumpAndSettle();

    final error = find.byKey(const ValueKey('prowlarr-indexers-write-error'));
    expect(error, findsOneWidget);
    expect(tester.getSemantics(error).flagsCollection.isLiveRegion, isTrue);
    expect(find.textContaining('private upstream detail'), findsNothing);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1200.0]) {
      testWidgets('${locale.languageCode} indexer hierarchy fits '
          '${width.toInt()}px at 2x text', (tester) async {
        final semantics = tester.ensureSemantics();
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final requests = <http.Request>[];
        final client = ProwlarrClient(
          config: _config,
          httpClient: MockClient((request) async {
            requests.add(request);
            return http.Response('{}', 200);
          }),
        );
        addTearDown(client.dispose);
        var reads = 0;

        try {
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                prowlarrConnectionProvider.overrideWith(_Connection.new),
                prowlarrClientProvider.overrideWith((_) => client),
                prowlarrIndexersProvider.overrideWith((_) async {
                  reads++;
                  return const [_indexer];
                }),
              ],
              child: _tabletApp(locale),
            ),
          );
          await tester.pumpAndSettle();
          final l10n = await AppLocalizations.delegate.load(locale);

          expect(find.byType(AppSurface), findsOneWidget);
          expect(find.byType(SettingsSection), findsAtLeastNWidgets(2));

          final heading = find.byKey(
            const ValueKey('prowlarr-indexers-section-title'),
          );
          final headingNode = tester.getSemantics(heading);
          expect(headingNode.label, 'Prowlarr');
          expect(headingNode.flagsCollection.isHeader, isTrue);
          expect(headingNode.flagsCollection.isButton, isFalse);

          final refresh = find.byKey(
            const ValueKey('prowlarr-indexers-refresh'),
          );
          final refreshNode = tester.getSemantics(refresh);
          expect(refreshNode.label, l10n.commonRefresh);
          expect(refreshNode.flagsCollection.isButton, isTrue);
          expect(refreshNode.rect.width, greaterThanOrEqualTo(48));
          expect(refreshNode.rect.height, greaterThanOrEqualTo(48));

          final toggle = find.byKey(
            const ValueKey('prowlarr-indexer-3-toggle'),
          );
          final toggleNode = tester.getSemantics(toggle);
          expect(toggleNode.label, 'Local Indexer');
          expect(toggleNode.flagsCollection.isEnabled, ui.Tristate.isTrue);
          expect(toggleNode.flagsCollection.isToggled, ui.Tristate.isTrue);
          expect(toggleNode.rect.width, greaterThanOrEqualTo(48));
          expect(toggleNode.rect.height, greaterThanOrEqualTo(48));
          expect(
            find.text(l10n.prowlarrIndexerSubtitle('torrent', 25)),
            findsOneWidget,
          );

          final refreshLabel = find.descendant(
            of: refresh,
            matching: find.text(l10n.commonRefresh),
          );
          Focus.of(tester.element(refreshLabel)).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(reads, 2);

          await _tabToToggle(tester);
          await tester.sendKeyEvent(LogicalKeyboardKey.space);
          await tester.pumpAndSettle();
          expect(requests, hasLength(1));
          expect(requests.single.method, 'PUT');
          expect(requests.single.body, contains('"enable":false'));
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });
    }
  }
}
