import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/media_preparations/presentation/server_media_preparations_screen.dart';
import 'package:larenor/features/server/plugins/presentation/server_plugins_screen.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/features/settings/presentation/settings_gate_screen.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server_media_preparations_test_support.dart';

void main() {
  late MediaPreparationsFixture f;
  final navigator = GlobalKey<NavigatorState>();
  Future<void> mount(
    WidgetTester tester, {
    bool gate = false,
    bool catalog = false,
    ValueNotifier<bool>? visible,
    AppInteractionController? interaction,
    String language = 'en',
    double scale = 1,
    double width = 1280,
    ServerRole role = ServerRole.admin,
    bool mustChange = false,
  }) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'settings_pin': '1234'});
    f = MediaPreparationsFixture(role: role, mustChange: mustChange);
    f.records.add(mediaPreparationJson());
    await f.account.initialize();
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Widget page = const ServerMediaPreparationsScreen();
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
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'history loads without mutation and an existing preparation opens and cancels',
    (tester) async {
      await mount(tester);
      expect(f.mutations, isEmpty);
      final id = f.records.single['id'];
      await tap(tester, 'media-view-$id');
      expect(
        find.textContaining('Installation has not started'),
        findsOneWidget,
      );
      await tap(tester, 'media-cancel');
      expect(find.textContaining('containers or media files'), findsOneWidget);
      expect(f.mutations, isEmpty);
      await tap(tester, 'media-cancel-confirm');
      expect(f.records.single['state'], 'cancelled');
      expect(find.byKey(const ValueKey('media-cancel')), findsNothing);
    },
  );
  testWidgets(
    'one explicit action creates a six component preparation without secret forms',
    (tester) async {
      await mount(tester);
      f.records.clear();
      await tap(tester, 'media-new');
      expect(f.mutations, isEmpty);
      expect(find.byType(CupertinoTextField), findsNWidgets(4));
      await tap(tester, 'media-create');
      expect(f.mutations, hasLength(1));
      expect(f.records, hasLength(1));
      expect(
        find.textContaining('Installation has not started'),
        findsOneWidget,
      );
      expect(
        f.calls.any(
          (r) =>
              r.url.path.contains('/jobs') || r.url.path.contains('/install'),
        ),
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'tablet Turkish at twice text scale supports keyboard and cancellation',
    (tester) async {
      await mount(tester, language: 'tr', scale: 2);
      await tap(tester, 'media-new');
      final field = find.byKey(const ValueKey('media-instanceName'));
      await tester.ensureVisible(field);
      await tester.tap(field);
      await tester.enterText(field, 'larenor');
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      await tap(tester, 'media-create');
      expect(find.textContaining('Kurulum başlatılmadı'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  for (final reason in [
    'background',
    'hidden',
    'account',
    'route',
    'idle',
    'pin',
  ]) {
    testWidgets(
      '$reason retires a pending confirmation and cannot send cancellation',
      (tester) async {
        final visible = ValueNotifier(true);
        final interaction = AppInteractionController();
        addTearDown(visible.dispose);
        addTearDown(interaction.dispose);
        await mount(tester, visible: visible, interaction: interaction);
        await tap(tester, 'media-view-${f.records.single['id']}');
        await tap(tester, 'media-cancel');
        final stale = tester
            .widget<CupertinoDialogAction>(
              find.byKey(const ValueKey('media-cancel-confirm')),
            )
            .onPressed!;
        switch (reason) {
          case 'background':
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.inactive,
            );
          case 'hidden':
            visible.value = false;
          case 'account':
            await f.account.signOut();
          case 'route':
            navigator.currentState!.push(
              CupertinoPageRoute<void>(
                builder: (_) =>
                    const CupertinoPageScaffold(child: Text('Covered')),
              ),
            );
          case 'idle':
            interaction.setActive(false);
          case 'pin':
            final container = ProviderScope.containerOf(
              tester.element(find.byType(ServerMediaPreparationsScreen)),
            );
            await container.read(pinLockProvider.notifier).setPin('5678');
        }
        await tester.pumpAndSettle();
        stale();
        await tester.pumpAndSettle();
        expect(f.mutations, isEmpty);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('media-cancel-confirm')),
          findsNothing,
        );
        expect(f.mutations, isEmpty);
      },
    );
  }
  testWidgets('member account never fetches preparations or offers creation', (
    tester,
  ) async {
    await mount(tester, role: ServerRole.member);
    expect(f.adminCalls, isEmpty);
    expect(find.byKey(const ValueKey('media-new')), findsNothing);
  });
  testWidgets(
    'component screen links the unified preparation while existing jobs remain available',
    (tester) async {
      await mount(tester, catalog: true);
      expect(find.byKey(const ValueKey('plugins-jobs')), findsOneWidget);
      await tap(tester, 'plugins-media');
      expect(find.byKey(const ValueKey('media-new')), findsOneWidget);
      expect(f.mutations, isEmpty);
    },
  );
  testWidgets(
    'PIN gate prevents any media read until unlock and Server entry',
    (tester) async {
      await mount(tester, gate: true);
      expect(f.adminCalls, isEmpty);
      await tester.enterText(find.byType(CupertinoTextField), '1234');
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Larenor Server'));
      await tester.pumpAndSettle();
      await tap(tester, 'server-plugins');
      await tap(tester, 'plugins-media');
      expect(find.byType(ServerMediaPreparationsScreen), findsOneWidget);
      expect(
        f.calls.any((r) => r.url.path.endsWith('/media/preparations')),
        isTrue,
      );
      expect(f.mutations, isEmpty);
    },
  );
  testWidgets('cancel conflict requires refresh and a new confirmation', (
    tester,
  ) async {
    await mount(tester);
    await tap(tester, 'media-view-${f.records.single['id']}');
    f.respond = (r) async => r.url.path.endsWith('/cancel')
        ? f.json({
            'error': {'code': 'revision_conflict'},
          }, 409)
        : f.pluginResponse(r);
    await tap(tester, 'media-cancel');
    await tap(tester, 'media-cancel-confirm');
    expect(
      tester
          .widget<CupertinoButton>(find.byKey(const ValueKey('media-cancel')))
          .onPressed,
      isNull,
    );
    expect(f.mutations, hasLength(1));
    await tester.pump(const Duration(minutes: 1));
    expect(f.mutations, hasLength(1));
    await tap(tester, 'media-refresh-selected');
    expect(
      tester
          .widget<CupertinoButton>(find.byKey(const ValueKey('media-cancel')))
          .onPressed,
      isNotNull,
    );
    expect(f.mutations, hasLength(1));
  });

  testWidgets('initial-password administrator cannot read or prepare media', (
    tester,
  ) async {
    await mount(tester, mustChange: true);
    expect(f.adminCalls, isEmpty);
    expect(find.byKey(const ValueKey('media-new')), findsNothing);
  });
  testWidgets(
    'lost create response offers explicit recovery of exactly one saved record',
    (tester) async {
      await mount(tester);
      f.records.clear();
      var writes = 0;
      f.respond = (r) async {
        final response = f.pluginResponse(r);
        if (r.method == 'POST' &&
            r.url.path.endsWith('/preparations') &&
            ++writes == 1)
          return http.Response('synthetic-secret', 502);
        return response;
      };
      await tap(tester, 'media-new');
      await tap(tester, 'media-create');
      expect(find.textContaining('result is uncertain'), findsOneWidget);
      expect(find.textContaining('synthetic-secret'), findsNothing);
      expect(f.records, hasLength(1));
      await tester.pump(const Duration(minutes: 1));
      expect(writes, 1);
      await tap(tester, 'media-recover');
      expect(writes, 2);
      expect(f.mutations.last.body, f.mutations.first.body);
      expect(f.records, hasLength(1));
      expect(
        find.textContaining('Installation has not started'),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'a delayed save completion stays hidden after the route is covered',
    (tester) async {
      await mount(tester);
      f.records.clear();
      await tap(tester, 'media-new');
      final held = Completer<http.Response>();
      f.respond = (r) =>
          r.method == 'POST' ? held.future : Future.value(f.pluginResponse(r));
      await tester.ensureVisible(find.byKey(const ValueKey('media-create')));
      await tester.tap(find.byKey(const ValueKey('media-create')));
      await tester.pump();
      unawaited(
        navigator.currentState!.push(
          CupertinoPageRoute<void>(
            builder: (_) => const CupertinoPageScaffold(child: Text('Cover')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      held.complete(f.json({'preparation': mediaPreparationJson()}, 201));
      await tester.pumpAndSettle();
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.textContaining('Installation has not started'), findsNothing);
      expect(find.byKey(const ValueKey('media-recover')), findsNothing);
      expect(f.mutations, hasLength(1));
    },
  );
  testWidgets(
    'an older active record remains reachable beyond one hundred cancelled preparations',
    (tester) async {
      await mount(tester);
      final rows = List.generate(
        101,
        (i) => pagedMediaPreparation(i + 1, cancelled: i < 100),
      );
      f.respond = (r) async {
        if (r.method == 'GET' && r.url.path.endsWith('/media/preparations')) {
          final before = int.tryParse(r.url.queryParameters['before'] ?? '');
          final start = before == null ? 0 : 102 - before;
          final page = rows.skip(start).take(10).toList();
          return f.json({
            'preparations': page,
            'nextBefore': start + 10 >= rows.length ? null : 92 - start,
          });
        }
        final selected = rows.last;
        if (r.url.path.endsWith('/${selected['id']}/cancel')) {
          selected['state'] = 'cancelled';
          selected['revision'] = 2;
          return f.json({'preparation': selected});
        }
        if (r.url.path.endsWith('/${selected['id']}'))
          return f.json({'preparation': selected});
        return f.pluginResponse(r);
      };
      await tap(tester, 'media-refresh');
      for (var page = 0; page < 10; page++) {
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('media-more')).hitTestable(),
          600,
          maxScrolls: 100,
        );
        await tap(tester, 'media-more');
      }
      final key = 'media-view-${rows.last['id']}';
      await tester.scrollUntilVisible(
        find.byKey(ValueKey(key)).hitTestable(),
        600,
        maxScrolls: 100,
      );
      await tap(tester, key);
      await tap(tester, 'media-cancel');
      await tap(tester, 'media-cancel-confirm');
      expect(rows.last['state'], 'cancelled');
      expect(f.mutations, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('common preparation inputs expose their localized labels to accessibility', (tester) async {
    final semantics = tester.ensureSemantics();
    addTearDown(semantics.dispose);
    await mount(tester);
    await tap(tester, 'media-new');
    final field = find.byKey(const ValueKey('media-instanceName'));
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    expect(tester.getSemantics(field).label, contains('Instance name'));
  });

}
