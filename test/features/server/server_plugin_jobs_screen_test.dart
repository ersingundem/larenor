import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/plugins/domain/server_plugin_models.dart';
import 'package:larenor/features/server/plugins/presentation/server_plugin_jobs_screen.dart';
import 'package:larenor/features/server/plugins/presentation/server_plugins_screen.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/features/settings/presentation/settings_gate_screen.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server_plugin_jobs_test_support.dart';
import 'server_plugins_test_support.dart';

void main() {
  late PluginJobsFixture f;
  final navigator = GlobalKey<NavigatorState>();
  Future<void> mount(
    WidgetTester tester, {
    bool configured = true,
    bool gate = false,
    bool catalog = false,
    bool preview = false,
    String state = 'queued',
    List<Map<String, Object?>>? checks,
    ValueNotifier<bool>? visible,
    AppInteractionController? interaction,
    String language = 'en',
    double scale = 1,
    double width = 1280,
    ServerRole role = ServerRole.admin,
  }) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'settings_pin': '1234'});
    f = PluginJobsFixture(role: role)
      ..configured = configured
      ..job = pluginJobJson(state: state);
    if (checks != null) f.job['result']['checks'] = checks;
    await f.account.initialize();
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Widget page = ServerPluginJobsScreen(
      preview: preview
          ? ServerPluginPreview.fromJson(pluginPreviewJson()['preview'])
          : null,
    );
    if (gate) page = const SettingsGateScreen();
    if (catalog) page = const ServerPluginsScreen();
    final target = page;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(f.account),
        ],
        child: CupertinoApp(
          navigatorKey: navigator,
          locale: Locale(language),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) {
            Widget view = MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            );
            if (interaction != null) {
              view = AppInteractionScope(controller: interaction, child: view);
            }
            return view;
          },
          home: visible == null
              ? target
              : ValueListenableBuilder(
                  valueListenable: visible,
                  builder: (_, enabled, _) =>
                      TickerMode(enabled: enabled, child: target),
                ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      f.account.dispose();
    });
  }

  Future<void> tap(WidgetTester tester, String key) async {
    final target = find.byKey(ValueKey(key));
    await tester.ensureVisible(target);
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  int selectedReads() => f.calls
      .where(
        (r) => r.method == 'GET' && r.url.path.endsWith('/jobs/${'a' * 32}'),
      )
      .length;

  testWidgets(
    'unconfigured worker still shows history and disables explicit launch',
    (tester) async {
      await mount(tester, configured: false, preview: true);
      expect(find.textContaining('worker is not configured'), findsOneWidget);
      expect(
        tester
            .widget<CupertinoButton>(find.byKey(const ValueKey('jobs-launch')))
            .onPressed,
        isNull,
      );
      await tap(tester, 'job-view-${'a' * 32}');
      expect(find.text('Queued'), findsWidgets);
      expect(f.mutations, isEmpty);
      expect(find.byType(CupertinoTextField), findsNothing);
    },
  );
  testWidgets(
    'configured launch needs an explicit action and shows actual mixed outcomes',
    (tester) async {
      await mount(tester, preview: true, state: 'succeeded');
      expect(f.mutations, isEmpty);
      expect(
        find.textContaining('connectivity has not been verified'),
        findsOneWidget,
      );
      await tap(tester, 'jobs-launch');
      expect(f.mutations, hasLength(1));
      expect(find.text('Inspection completed'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Not met'), 300);
      expect(find.text('Not met'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Could not verify'), 300);
      expect(find.text('Could not verify'), findsOneWidget);
      expect(f.calls.any((r) => r.url.path.contains('/install')), isFalse);
      expect(tester.takeException(), isNull);
    },
  );
  for (final locale in [
    (
      language: 'en',
      scale: 1.0,
      docker: 'Docker API and platform compatibility',
      root: 'Worker-local storage root',
      capacity: 'Worker-local storage capacity',
      mount: 'Docker daemon mount context',
      network: 'Docker daemon network context',
      daemonRoot: 'Docker daemon root context',
      ports: 'Port availability',
      receiver: 'Receiver network',
      passed: 'Passed',
      unknown: 'Could not verify',
      completed: 'Inspection completed',
      note: 'completion does not mean every requirement passed',
    ),
    (
      language: 'tr',
      scale: 2.0,
      docker: 'Docker API ve platform uyumluluğu',
      root: 'Çalışanın yerel depolama alanı',
      capacity: 'Çalışanın yerel depolama kapasitesi',
      mount: 'Docker daemon bağlama bağlamı',
      network: 'Docker daemon ağ bağlamı',
      daemonRoot: 'Docker daemon kök bağlamı',
      ports: 'Port kullanılabilirliği',
      receiver: 'Alıcı ağı',
      passed: 'Karşılandı',
      unknown: 'Doğrulanamadı',
      completed: 'İnceleme tamamlandı',
      note: 'tamamlanması tüm gereksinimlerin karşılandığı',
    ),
  ]) {
    testWidgets(
      '${locale.language} tablet distinguishes Docker compatibility from unchecked network requirements',
      (tester) async {
        await mount(
          tester,
          state: 'succeeded',
          language: locale.language,
          scale: locale.scale,
          checks: [
            for (final code in [
              'docker_engine',
              'storage_root',
              'storage_capacity',
              'daemon_mount_context',
              'daemon_network_context',
              'daemon_root_context',
              'port_availability',
              'receiver_network',
            ])
              {
                'code': code,
                'status': code == 'docker_engine' || code.startsWith('storage_')
                    ? 'passed'
                    : 'unknown',
                'rootId': null,
                'availableMiB': null,
                'requiredMiB': null,
              },
          ],
        );
        await tap(tester, 'job-view-${'a' * 32}');
        expect(find.text(locale.completed), findsOneWidget);
        expect(find.textContaining(locale.note), findsOneWidget);

        for (final result in [
          (label: locale.docker, status: locale.passed),
          (label: locale.root, status: locale.passed),
          (label: locale.capacity, status: locale.passed),
          (label: locale.mount, status: locale.unknown),
          (label: locale.network, status: locale.unknown),
          (label: locale.daemonRoot, status: locale.unknown),
          (label: locale.ports, status: locale.unknown),
          (label: locale.receiver, status: locale.unknown),
        ]) {
          final label = find.text(result.label);
          expect(label, findsOneWidget);
          await tester.ensureVisible(label);
          await tester.pumpAndSettle();
          final row = find
              .ancestor(of: label, matching: find.byType(Column))
              .first;
          expect(
            find.descendant(of: row, matching: find.text(result.status)),
            findsOneWidget,
          );
        }

        expect(find.byKey(const ValueKey('jobs-cancel')), findsNothing);
        expect(f.mutations, isEmpty);
        expect(f.calls.any((r) => r.url.path.contains('/install')), isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'active status polls one request at a time and stops when terminal',
    (tester) async {
      await mount(tester);
      await tap(tester, 'job-view-${'a' * 32}');
      expect(selectedReads(), 1);
      final held = Completer<http.Response>();
      f.respond = (r) => r.url.path.endsWith('/jobs/${'a' * 32}')
          ? held.future
          : Future.value(f.pluginResponse(r));
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(selectedReads(), 2);
      await tester.pump(const Duration(seconds: 10));
      expect(selectedReads(), 2);
      held.complete(
        f.json({'job': pluginJobJson(state: 'succeeded', revision: 2)}),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 60));
      expect(selectedReads(), 2);
      expect(find.text('Inspection completed'), findsOneWidget);
    },
  );
  testWidgets(
    'foreground polling has a finite budget and explicit refresh restarts it',
    (tester) async {
      await mount(tester);
      await tap(tester, 'job-view-${'a' * 32}');
      for (var i = 0; i < 61; i++) {
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
      }
      expect(selectedReads(), 61);
      expect(
        find.textContaining('Automatic status checks paused'),
        findsOneWidget,
      );
      await tap(tester, 'job-refresh');
      expect(selectedReads(), 62);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(selectedReads(), 63);
    },
  );
  testWidgets('an uncertain poll stops automatic retries', (tester) async {
    await mount(tester);
    await tap(tester, 'job-view-${'a' * 32}');
    f.respond = (_) async => throw http.ClientException('synthetic-secret');
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    final reads = selectedReads();
    await tester.pump(const Duration(seconds: 30));
    expect(selectedReads(), reads);
    expect(find.textContaining('synthetic-secret'), findsNothing);
    expect(f.mutations, isEmpty);
  });
  testWidgets('hiding the route clears a confirmation and its stale callback', (
    tester,
  ) async {
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    await mount(tester, visible: visible);
    await tap(tester, 'job-view-${'a' * 32}');
    await tap(tester, 'jobs-cancel');
    final action = tester
        .widget<CupertinoDialogAction>(
          find.byKey(const ValueKey('jobs-cancel-confirm')),
        )
        .onPressed!;
    visible.value = false;
    await tester.pumpAndSettle();
    action();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('jobs-cancel-confirm')), findsNothing);
    expect(f.mutations, isEmpty);
    final reads = selectedReads();
    await tester.pump(const Duration(seconds: 30));
    expect(selectedReads(), reads);
    visible.value = true;
    await tester.pumpAndSettle();
    expect(find.textContaining('Open Settings'), findsOneWidget);
  });
  testWidgets(
    'backgrounding clears results and prevents a stale cancellation',
    (tester) async {
      await mount(tester);
      await tap(tester, 'job-view-${'a' * 32}');
      await tap(tester, 'jobs-cancel');
      final action = tester
          .widget<CupertinoDialogAction>(
            find.byKey(const ValueKey('jobs-cancel-confirm')),
          )
          .onPressed!;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      action();
      await tester.pump();
      expect(f.mutations, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('jobs-cancel')), findsNothing);
    },
  );
  testWidgets(
    'fresh cancellation submits the reviewed revision and ends polling',
    (tester) async {
      await mount(tester);
      await tap(tester, 'job-view-${'a' * 32}');
      await tap(tester, 'jobs-cancel');
      expect(
        find.textContaining('No installed service or media file is removed'),
        findsOneWidget,
      );
      await tap(tester, 'jobs-cancel-confirm');
      expect(f.mutations, hasLength(1));
      expect(find.text('Cancelled'), findsOneWidget);
      final reads = selectedReads();
      await tester.pump(const Duration(seconds: 30));
      expect(selectedReads(), reads);
    },
  );
  testWidgets(
    'a covered confirmation cannot submit after another route appears',
    (tester) async {
      await mount(tester);
      await tap(tester, 'job-view-${'a' * 32}');
      await tap(tester, 'jobs-cancel');
      final action = tester
          .widget<CupertinoDialogAction>(
            find.byKey(const ValueKey('jobs-cancel-confirm')),
          )
          .onPressed!;
      unawaited(
        navigator.currentState!.push(
          CupertinoPageRoute<void>(
            builder: (_) => const CupertinoPageScaffold(child: Text('Cover')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      action();
      await tester.pumpAndSettle();
      expect(f.mutations, isEmpty);
    },
  );
  for (final reason in ['idle', 'account', 'pin']) {
    testWidgets('$reason retires a saved cancellation callback and polling', (
      tester,
    ) async {
      final interaction = AppInteractionController();
      addTearDown(interaction.dispose);
      await mount(tester, interaction: interaction);
      await tap(tester, 'job-view-${'a' * 32}');
      await tap(tester, 'jobs-cancel');
      final action = tester
          .widget<CupertinoDialogAction>(
            find.byKey(const ValueKey('jobs-cancel-confirm')),
          )
          .onPressed!;
      switch (reason) {
        case 'idle':
          interaction.setActive(false);
          await tester.pump();
          interaction.setActive(true);
        case 'account':
          await f.account.signOut();
        case 'pin':
          final container = ProviderScope.containerOf(
            tester.element(find.byType(ServerPluginJobsScreen)),
          );
          await container.read(pinLockProvider.notifier).setPin('5678');
      }
      await tester.pumpAndSettle();
      action();
      await tester.pumpAndSettle();
      expect(f.mutations, isEmpty);
      expect(find.byKey(const ValueKey('jobs-cancel-confirm')), findsNothing);
      final reads = selectedReads();
      await tester.pump(const Duration(seconds: 30));
      expect(selectedReads(), reads);
    });
  }
  testWidgets(
    'a cancellation revision conflict needs a fresh explicit status read',
    (tester) async {
      await mount(tester);
      await tap(tester, 'job-view-${'a' * 32}');
      f.respond = (request) async => request.url.path.endsWith('/cancel')
          ? f.json({
              'error': {'code': 'revision_conflict'},
            }, 409)
          : f.pluginResponse(request);
      await tap(tester, 'jobs-cancel');
      await tap(tester, 'jobs-cancel-confirm');
      expect(find.textContaining('This check changed'), findsOneWidget);
      expect(
        tester
            .widget<CupertinoButton>(find.byKey(const ValueKey('jobs-cancel')))
            .onPressed,
        isNull,
      );
      final calls = f.mutations.length;
      await tester.pump(const Duration(seconds: 30));
      expect(f.mutations, hasLength(calls));
      await tap(tester, 'job-refresh');
      expect(
        tester
            .widget<CupertinoButton>(find.byKey(const ValueKey('jobs-cancel')))
            .onPressed,
        isNotNull,
      );
    },
  );
  testWidgets('read-only users cannot read jobs or capabilities', (
    tester,
  ) async {
    await mount(tester, role: ServerRole.member);
    expect(f.adminCalls, isEmpty);
    expect(f.mutations, isEmpty);
  });
  testWidgets(
    'PIN-protected component entry reaches history only after unlock',
    (tester) async {
      await mount(tester, gate: true);
      expect(f.adminCalls, isEmpty);
      await tester.enterText(find.byType(CupertinoTextField), '1234');
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Larenor Server'));
      await tester.pumpAndSettle();
      await tap(tester, 'server-plugins');
      await tap(tester, 'plugins-jobs');
      expect(find.byType(ServerPluginJobsScreen), findsOneWidget);
      expect(
        f.calls.any((r) => r.url.path.endsWith('/jobs/capabilities')),
        isTrue,
      );
      expect(f.mutations, isEmpty);
    },
  );
  testWidgets(
    'catalog preview hands the reviewed plan to an explicit check screen',
    (tester) async {
      await mount(tester, catalog: true);
      await tap(tester, 'plugin-review-jellyfin');
      await tap(tester, 'plugin-platform-linux/amd64');
      await tap(tester, 'plugin-preview-submit');
      await tap(tester, 'plugin-preview-inspect');
      expect(find.byType(ServerPluginJobsScreen), findsOneWidget);
      expect(f.mutations.where((r) => r.url.path.endsWith('/jobs')), isEmpty);
      await tap(tester, 'jobs-launch');
      expect(
        f.mutations.where((r) => r.url.path.endsWith('/jobs')),
        hasLength(1),
      );
    },
  );
  testWidgets('lost submission recovery is explicit and uses the same body', (
    tester,
  ) async {
    await mount(tester, preview: true);
    var writes = 0;
    f.respond = (request) async {
      if (request.method == 'POST' &&
          request.url.path.endsWith('/jobs') &&
          ++writes == 1) {
        return http.Response('synthetic-secret', 502);
      }
      return f.pluginResponse(request);
    };
    await tap(tester, 'jobs-launch');
    expect(find.textContaining('submission result is unknown'), findsOneWidget);
    expect(find.textContaining('synthetic-secret'), findsNothing);
    await tester.pump(const Duration(seconds: 30));
    expect(writes, 1);
    await tap(tester, 'jobs-recover');
    expect(writes, 2);
    expect(f.mutations.elementAt(1).body, f.mutations.first.body);
    expect(find.text('Queued'), findsWidgets);
  });
  testWidgets(
    'history and activity use their returned cursors on explicit pagination',
    (tester) async {
      await mount(tester);
      final second = {
        ...pluginJobJson(state: 'failed', revision: 3),
        'id': 'b' * 32,
        'requestId': 'c' * 32,
      };
      f.respond = (request) async {
        if (request.url.path.endsWith('/jobs')) {
          return f.json({
            'jobs': request.url.queryParameters['before'] == null
                ? [pluginJobJson()]
                : [second],
            'nextBefore': request.url.queryParameters['before'] == null
                ? 50
                : null,
          });
        }
        if (request.url.path.endsWith('/jobs/${'b' * 32}')) {
          return f.json({'job': second});
        }
        if (request.url.path.endsWith('/events')) {
          return f.json({
            'events': [
              pluginJobEventJson(
                sequence: request.url.queryParameters['after'] == '0' ? 1 : 2,
                code: request.url.queryParameters['after'] == '0'
                    ? 'job_queued'
                    : 'job_failed',
                revision: request.url.queryParameters['after'] == '0' ? 1 : 3,
              ),
            ],
            'nextAfter': request.url.queryParameters['after'] == '0' ? 1 : null,
          });
        }
        return f.pluginResponse(request);
      };
      await tap(tester, 'jobs-refresh');
      await tap(tester, 'jobs-more');
      expect(f.calls.last.url.queryParameters, {'before': '50', 'limit': '25'});
      await tap(tester, 'job-view-${'b' * 32}');
      await tap(tester, 'job-more-events');
      expect(f.calls.last.url.queryParameters, {'after': '1', 'limit': '25'});
      expect(find.textContaining('Inspection failed'), findsWidgets);
      expect(f.mutations, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Turkish tablet at 2x text keeps check actions usable with a keyboard',
    (tester) async {
      await mount(tester, preview: true, language: 'tr', scale: 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, isNotNull);
      await tap(tester, 'jobs-launch');
      await tap(tester, 'jobs-cancel');
      expect(
        find.text('Bu gereksinim denetimi iptal edilsin mi?'),
        findsOneWidget,
      );
      await tap(tester, 'jobs-cancel-confirm');
      expect(tester.takeException(), isNull);
      expect(f.mutations, hasLength(2));
    },
  );
}
