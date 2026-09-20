import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/admin/data/admin_client.dart';
import 'package:larenor/features/admin/data/models/automation_summary.dart';
import 'package:larenor/features/admin/presentation/automations_screen.dart';
import 'package:larenor/features/admin/providers/admin_providers.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';
import 'package:larenor/features/ha_client/data/rest_client.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/health/data/health_monitor.dart';
import 'package:larenor/features/health/data/integration_health.dart';
import 'package:larenor/features/health/providers/health_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/service_root_scaffold.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

import 'admin_test_fakes.dart';

const _summary = AutomationSummary(
  entityId: 'automation.movie_night',
  friendlyName: 'Movie Night',
  isOn: true,
  automationId: 'movie-night',
);

const _entity = HaEntity(
  entityId: 'automation.movie_night',
  state: 'on',
  attributes: {'friendly_name': 'Movie Night'},
);

class _Entities extends Entities {
  @override
  Future<Map<String, HaEntity>> build() async => const {
    'automation.movie_night': _entity,
  };
}

class _Fixture {
  const _Fixture({
    required this.rest,
    required this.admin,
    required this.health,
    required this.calls,
  });
  final HaRestClient rest;
  final HaAdminClient admin;
  final HealthMonitor health;
  final List<String> calls;
}

_Fixture _fixture() {
  final calls = <String>[];
  final rest = HaRestClient(
    baseUrl: 'http://ha.invalid',
    token: 'fixture-only',
    httpClient: MockClient((request) async {
      calls.add('${request.method} ${request.url.path}');
      return http.Response('[]', 200);
    }),
  );
  final health = HealthMonitor();
  health.bind(IntegrationId.ha, configured: true).readSucceeded();
  return _Fixture(
    rest: rest,
    admin: HaAdminClient(rest, RecordingAdminSocket()),
    health: health,
    calls: calls,
  );
}

List<Override> _overrides(
  _Fixture fixture, {
  Future<List<AutomationSummary>> Function()? load,
}) => [
  haRestClientProvider.overrideWith((ref) => fixture.rest),
  haAdminClientProvider.overrideWithValue(fixture.admin),
  healthMonitorProvider.overrideWithValue(fixture.health),
  entitiesProvider.overrideWith(_Entities.new),
  automationsProvider.overrideWith(
    (ref) => load?.call() ?? Future.value(const [_summary]),
  ),
];

Future<_Fixture> _mount(
  WidgetTester tester, {
  String language = 'en',
  double width = 600,
  Future<List<AutomationSummary>> Function()? load,
  bool settle = true,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fixture = _fixture();
  addTearDown(fixture.rest.dispose);
  addTearDown(fixture.health.dispose);
  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      retry: (count, error) => null,
      overrides: _overrides(fixture, load: load),
      child: CupertinoApp(
        locale: Locale(language),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: const AutomationsScreen(),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return fixture;
}

void main() {
  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets(
        '$language ${width.toInt()} 2x automation controls use the tablet contract',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            final fixture = await _mount(
              tester,
              language: language,
              width: width,
            );
            expect(find.byType(ServiceRootScaffold), findsOneWidget);
            expect(find.byType(SettingsSection), findsAtLeastNWidgets(1));
            final l10n = AppLocalizations.of(
              tester.element(find.byType(ServiceRootScaffold)),
            );
            expect(
              tester
                  .getSemantics(find.byKey(const ValueKey('health-status-ha')))
                  .label,
              contains(l10n.healthReadCurrent),
            );
            for (final key in const [
              'automations-refresh',
              'automations-add',
            ]) {
              final target = find.byKey(ValueKey(key));
              expect(target, findsOneWidget);
              expect(tester.getRect(target).height, greaterThanOrEqualTo(44));
              expect(
                tester.getSemantics(target).flagsCollection.isButton,
                isTrue,
                reason: key,
              );
            }
            for (final key in const [
              'automation-action-automation.movie_night',
              'automation-toggle-automation.movie_night',
            ]) {
              final target = find.byKey(ValueKey(key));
              expect(target, findsOneWidget);
              expect(tester.getRect(target).height, greaterThanOrEqualTo(48));
              expect(
                tester.getSemantics(target).flagsCollection.isButton,
                isTrue,
                reason: key,
              );
            }
            expect(
              tester
                  .getSemantics(
                    find.byKey(
                      const ValueKey(
                        'automation-toggle-automation.movie_night',
                      ),
                    ),
                  )
                  .flagsCollection
                  .isToggled,
              ui.Tristate.isTrue,
            );
            final toggle = find.byKey(
              const ValueKey(
                'automation-toggle-control-automation.movie_night',
              ),
            );
            Focus.of(
              tester.element(
                find.descendant(
                  of: toggle,
                  matching: find.byType(CupertinoSwitch),
                ),
              ),
            ).requestFocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pumpAndSettle();
            expect(fixture.calls, ['POST /api/services/automation/turn_off']);
            expect(tester.takeException(), isNull);
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }

  testWidgets(
    'loading empty and failure are distinct secret-free live states',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final pending = Completer<List<AutomationSummary>>();
        await _mount(tester, load: () => pending.future, settle: false);
        final loading = find.byKey(const ValueKey('automations-loading'));
        expect(loading, findsOneWidget);
        expect(
          tester.getSemantics(loading).flagsCollection.isLiveRegion,
          isTrue,
        );

        await _mount(tester, load: () async => const []);
        final empty = find.byKey(const ValueKey('automations-empty'));
        expect(empty, findsOneWidget);
        expect(tester.getSemantics(empty).flagsCollection.isLiveRegion, isTrue);

        await _mount(
          tester,
          load: () async => throw StateError('secret-token-private'),
        );
        final error = find.byKey(const ValueKey('automations-error'));
        expect(error, findsOneWidget);
        expect(tester.getSemantics(error).flagsCollection.isLiveRegion, isTrue);
        expect(find.textContaining('secret-token-private'), findsNothing);
        expect(
          tester
              .getRect(find.byKey(const ValueKey('automations-retry')))
              .height,
          greaterThanOrEqualTo(48),
        );
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('captured actions fail closed after authority or route changes', (
    tester,
  ) async {
    final old = await _mount(tester);
    final toggle = tester
        .widget<CupertinoButton>(
          find.byKey(
            const ValueKey('automation-toggle-control-automation.movie_night'),
          ),
        )
        .onPressed!;
    final context = tester.element(find.byType(AutomationsScreen));
    final container = ProviderScope.containerOf(context);
    final replacement = _fixture();
    addTearDown(replacement.rest.dispose);
    addTearDown(replacement.health.dispose);
    container.updateOverrides(_overrides(replacement));
    await tester.pumpAndSettle();
    toggle();
    await tester.pump();
    expect(old.calls, isEmpty);
    expect(replacement.calls, isEmpty);

    final covered = await _mount(tester);
    final coveredToggle = tester
        .widget<CupertinoButton>(
          find.byKey(
            const ValueKey('automation-toggle-control-automation.movie_night'),
          ),
        )
        .onPressed!;
    final navigator = Navigator.of(
      tester.element(find.byType(AutomationsScreen)),
    );
    unawaited(
      navigator.push<void>(
        CupertinoPageRoute<void>(
          builder: (_) => const CupertinoPageScaffold(child: Text('Cover')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    coveredToggle();
    await tester.pump();
    expect(covered.calls, isEmpty);
  });
}
