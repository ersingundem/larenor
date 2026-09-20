import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/admin/presentation/pending_flows_screen.dart';
import 'package:larenor/features/admin/providers/admin_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/service_root_scaffold.dart';
import 'package:larenor/shared/widgets/settings_action_tile.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

import 'admin_test_fakes.dart';

Future<(RecordingAdminSocket, List<http.Request>)> _mount(
  WidgetTester tester, {
  required String language,
  required double width,
  Future<Object?> Function(int attempt)? pendingResponse,
}) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  var attempts = 0;
  final socket = RecordingAdminSocket(
    respond: (_) {
      attempts++;
      return pendingResponse?.call(attempts) ??
          [
            {
              'flow_id': 'reauth-1',
              'handler': 'cloud',
              'context': {'source': 'reauth'},
            },
          ];
    },
  );
  final requests = <http.Request>[];
  final client = fakeAdminClient(
    socket,
    respond: (request) async {
      requests.add(request);
      return http.Response(
        jsonEncode({
          'type': 'abort',
          'flow_id': 'reauth-1',
          'reason': 'finished',
        }),
        200,
      );
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
        home: const PendingFlowsScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (socket, requests);
}

void main() {
  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets('$language pending flows are accessible at ${width}px 2x', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        try {
          final (_, requests) = await _mount(
            tester,
            language: language,
            width: width,
          );
          expect(find.byType(ServiceRootScaffold), findsOneWidget);
          expect(find.byType(SettingsSection), findsOneWidget);
          expect(find.byType(SettingsActionTile), findsOneWidget);
          expect(
            tester
                .getSemantics(
                  find.byKey(const ValueKey('pending-flows-heading')),
                )
                .flagsCollection
                .isHeader,
            isTrue,
          );

          final flow = find.byKey(const ValueKey('pending-flow-reauth-1'));
          expect(tester.getRect(flow).height, greaterThanOrEqualTo(48));
          expect(tester.getSemantics(flow).flagsCollection.isButton, isTrue);
          Focus.of(
            tester.element(
              find.descendant(of: flow, matching: find.text('cloud')),
            ),
          ).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();

          expect(requests.map((request) => request.method), ['GET']);
          expect(find.text('finished'), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });
    }
  }

  testWidgets('pending flow error retries through the shared action row', (
    tester,
  ) async {
    final (socket, _) = await _mount(
      tester,
      language: 'en',
      width: 600,
      pendingResponse: (attempt) async {
        if (attempt == 1) throw StateError('offline');
        return [
          {'flow_id': 'reauth-1', 'handler': 'cloud'},
        ];
      },
    );
    final retry = find.byKey(const ValueKey('pending-flows-retry-action'));
    expect(tester.getRect(retry).height, greaterThanOrEqualTo(48));
    expect(tester.getSemantics(retry).flagsCollection.isButton, isTrue);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(socket.commands, hasLength(2));
    expect(find.byKey(const ValueKey('pending-flow-reauth-1')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('captured pending flow expires after lifecycle return', (
    tester,
  ) async {
    final (_, requests) = await _mount(tester, language: 'en', width: 600);
    final old = tester
        .widget<CupertinoButton>(
          find.byKey(const ValueKey('pending-flow-reauth-1')),
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
    expect(requests, isEmpty);
    expect(find.textContaining('app session changed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
