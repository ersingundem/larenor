import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/proxmox/data/models/proxmox_task.dart';
import 'package:larenor/features/proxmox/data/proxmox_client.dart';
import 'package:larenor/features/proxmox/data/proxmox_config.dart';
import 'package:larenor/features/proxmox/presentation/proxmox_tasks_screen.dart';
import 'package:larenor/features/proxmox/providers/proxmox_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

const _app = CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: Locale('en'),
  home: ProxmoxTasksScreen(nodeName: 'pve'),
);

void main() {
  testWidgets('slow task-list reads do not overlap or poll in background', (
    tester,
  ) async {
    final pending = <Completer<List<ProxmoxTask>>>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
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
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    pending.last.complete([]);
    await tester.pump(const Duration(minutes: 5));
    expect(pending, hasLength(2));
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
        config: const ProxmoxConfig(
          host: 'pve.test',
          port: 8006,
          username: 'root',
          realm: 'pam',
          password: 'example',
          allowSelfSigned: false,
        ),
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
}
