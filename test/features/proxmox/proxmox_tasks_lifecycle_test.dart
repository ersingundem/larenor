import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/proxmox/data/models/proxmox_task.dart';
import 'package:larenor/features/proxmox/data/proxmox_client.dart';

import 'proxmox_transport_security_test.dart' show fixtureConfig;

import 'package:larenor/features/proxmox/presentation/proxmox_tasks_screen.dart';
import 'package:larenor/features/proxmox/providers/proxmox_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/app_page_scaffold.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

import 'proxmox_providers_test.dart' show ControlledConnection;

const _app = CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: Locale('en'),
  home: ProxmoxTasksScreen(nodeName: 'pve'),
);

Widget _tabletApp(Locale locale) => CupertinoApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context)
        .copyWith(textScaler: const TextScaler.linear(2)),
    child: child!,
  ),
  home: const ProxmoxTasksScreen(nodeName: 'pve'),
);

Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
}

void main() {
  testWidgets('slow task-list reads do not overlap or poll in background', (
    tester,
  ) async {
    final pending = <Completer<List<ProxmoxTask>>>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          proxmoxConnectionProvider.overrideWith(ControlledConnection.new),
          proxmoxTasksProvider('pve').overrideWith((ref) {
            final result = Completer<List<ProxmoxTask>>();
            pending.add(result);
            return result.future;
          }),
        ],
        child: _app,
      ),
    );
    await tester.pump(const Duration(seconds: 30));
    expect(pending, hasLength(1));
    pending.first.complete([]);
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(pending, hasLength(2));
    await tester.pump(const Duration(seconds: 30));
    expect(pending, hasLength(2));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    pending.last.complete([]);
    await tester.pump(const Duration(minutes: 5));
    expect(pending, hasLength(2));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(pending, hasLength(3));
    await tester.pumpWidget(const SizedBox());
    pending.last.complete([]);
    await tester.pump(const Duration(seconds: 30));
    expect(pending, hasLength(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'leaving a pending task status never starts a log request afterward',
    (tester) async {
      final status = Completer<http.Response>();
      final requests = <String>[];
      final client = ProxmoxClient(
        config: fixtureConfig,
        httpClient: MockClient((request) async {
          requests.add(request.url.path);
          if (request.url.path.endsWith('/access/ticket')) {
            return http.Response(
              jsonEncode({
                'data': {'ticket': 'example', 'CSRFPreventionToken': 'example'},
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/status')) return status.future;
          return http.Response(jsonEncode({'data': []}), 200);
        }),
      );
      addTearDown(client.dispose);
      await client.login();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            proxmoxConnectionProvider.overrideWith(ControlledConnection.new),
            proxmoxClientProvider.overrideWith((ref) async => client),
            proxmoxTasksProvider('pve').overrideWith(
              (ref) async => const [
                ProxmoxTask(upid: 'UPID:pve:1', type: 'backup'),
              ],
            ),
          ],
          child: _app,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('backup'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(requests.where((path) => path.endsWith('/status')), hasLength(1));
      await tester.pumpWidget(const SizedBox());
      status.complete(
        http.Response(
          jsonEncode({
            'data': {'status': 'running'},
          }),
          200,
        ),
      );
      await tester.pump();
      expect(requests.where((path) => path.endsWith('/log')), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1200.0]) {
      testWidgets('${locale.languageCode} task hierarchy fits '
          '${width.toInt()}px at 2x text', (tester) async {
        final semantics = tester.ensureSemantics();
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        var reads = 0;
        try {
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                proxmoxConnectionProvider.overrideWith(
                  ControlledConnection.new,
                ),
                proxmoxTasksProvider('pve').overrideWith((_) async {
                  reads++;
                  return const [
                    ProxmoxTask(
                      upid: 'UPID:pve:fixture',
                      type: 'backup',
                      resourceId: 'vm-100',
                    ),
                  ];
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
            const ValueKey('proxmox-tasks-section-title'),
          );
          final headingNode = tester.getSemantics(heading);
          expect(headingNode.label, l10n.proxmoxTasksTitle);
          expect(headingNode.flagsCollection.isHeader, isTrue);
          expect(headingNode.flagsCollection.isButton, isFalse);

          for (final key in const [
            'proxmox-tasks-refresh',
            'proxmox-task-UPID:pve:fixture',
          ]) {
            final action = find.byKey(ValueKey(key));
            final rect = tester.getRect(action);
            expect(rect.width, greaterThanOrEqualTo(48));
            expect(rect.height, greaterThanOrEqualTo(48));
            expect(
              tester.getSemantics(action).flagsCollection.isButton,
              isTrue,
            );
          }
          expect(
            tester.widgetList<CupertinoButton>(find.byType(CupertinoButton)),
            everyElement(
              predicate<CupertinoButton>(
                (button) => (button.minimumSize?.height ?? 0) >= 48,
              ),
            ),
          );

          Focus.of(tester.element(find.text(l10n.commonRefresh)))
              .requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await frames(tester);
          expect(reads, 2);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });
    }
  }
}
