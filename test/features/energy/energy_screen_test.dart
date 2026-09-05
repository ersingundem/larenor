import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/energy/data/energy_period.dart';
import 'package:larenor/features/energy/domain/energy_models.dart';
import 'package:larenor/features/energy/domain/maintenance_models.dart';
import 'package:larenor/features/energy/presentation/energy_maintenance_screen.dart';
import 'package:larenor/features/energy/providers/energy_providers.dart';
import 'package:larenor/features/ha_client/data/ws_client.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/proxmox/data/models/proxmox_node.dart';
import 'package:larenor/features/proxmox/data/proxmox_config.dart';
import 'package:larenor/features/proxmox/providers/proxmox_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import 'energy_fixture.dart';

class _Connection extends ConnectionConfig {
  @override
  Future<HaConnectionConfig?> build() async => const HaConnectionConfig(
    baseUrl: 'http://fixture.test',
    token: 'fixture',
  );
  void change() => state = const AsyncData(
    HaConnectionConfig(
      baseUrl: 'http://fixture.test',
      token: 'replacement-fixture',
    ),
  );
}

class _Proxmox extends ProxmoxConnection {
  _Proxmox(this.configured);
  final bool configured;
  @override
  Future<ProxmoxConfig?> build() async => configured
      ? const ProxmoxConfig(
          host: 'proxmox.test',
          port: 8006,
          username: 'fixture',
          realm: 'pam',
          password: 'fixture',
          allowSelfSigned: false,
        )
      : null;
}

EnergyMeterReading _meter(
  String id, {
  double? value = 3,
  String? unit = 'kWh',
  String? parent,
  Set<EnergyCoverageIssue> issues = const {},
}) {
  final period = buildEnergyPeriod('UTC', energyNow, EnergyRange.today);
  return EnergyMeterReading(
    definition: EnergyMeterDefinition(
      statisticId: id,
      role: EnergyRole.deviceConsumption,
      includedInStatisticId: parent,
    ),
    name: id,
    unit: unit,
    daily: [
      EnergyDayReading(
        window: period.days.single,
        reportedValue: value,
        expectedHours: 12,
        receivedHours: 12,
        hasBaseline: !issues.contains(EnergyCoverageIssue.missingBaseline),
        issues: issues,
      ),
    ],
  );
}

EnergyViewState _state(List<EnergyMeterReading> meters) => EnergyViewState(
  snapshot: EnergySnapshot(
    energyConfigured: true,
    readAt: energyNow,
    period: buildEnergyPeriod('UTC', energyNow, EnergyRange.today),
    meters: meters,
  ),
);
MaintenanceItem _item(String id) => MaintenanceItem(
  entityId: id,
  name: id,
  kinds: {MaintenanceKind.lowBattery},
  batteryPercent: 10,
);

class _Harness {
  _Harness({
    EnergyViewState? state,
    this.realReader = false,
    this.nodes = const [],
    this.selected = const [],
    this.all = const [],
  }) : current = state ?? _state([]);
  EnergyViewState? current;
  final bool realReader;
  final List<ProxmoxNode> nodes;
  final List<MaintenanceItem> selected, all;
  final api = FakeEnergyApi();
  final changes = StreamController<EnergyViewState>.broadcast(sync: true);
  final visible = ValueNotifier(true);
  late ProviderContainer container;
  late GoRouter router;
  int nodeReads = 0;
  Completer<List<ProxmoxNode>>? nodeGate;
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await frames(tester);
  }

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(600, 1100),
    double scale = 1,
  }) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        connectionConfigProvider.overrideWith(_Connection.new),
        energyApiProvider.overrideWith((_) => api),
        energyClockProvider.overrideWithValue(() => energyNow),
        haConnectionStatusProvider.overrideWith(
          (_) => Stream.value(HaConnectionStatus.disconnected),
        ),
        if (!realReader)
          energyProvider.overrideWith(
            (_) => Stream.multi((sink) {
              if (current != null) sink.add(current!);
              final listener = changes.stream.listen(
                sink.add,
                onError: sink.addError,
              );
              sink.onCancel = listener.cancel;
            }),
          ),
        maintenanceProvider.overrideWith(
          (ref, scope) => MaintenanceSnapshot(
            scope: scope,
            checkedEntities: scope == MaintenanceScope.selected
                ? selected.length
                : all.length,
            items: scope == MaintenanceScope.selected ? selected : all,
          ),
        ),
        proxmoxConnectionProvider.overrideWith(
          () => _Proxmox(nodes.isNotEmpty),
        ),
        proxmoxNodesProvider.overrideWith((_) async {
          nodeReads++;
          return nodeGate?.future ?? nodes;
        }),
      ],
    );
    await container.read(connectionConfigProvider.future);
    router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => ValueListenableBuilder(
            valueListenable: visible,
            builder: (context, value, child) =>
                TickerMode(enabled: value, child: child!),
            child: const EnergyMaintenanceScreen(),
          ),
        ),
        GoRoute(
          path: '/entities/:id',
          builder: (_, state) => CupertinoPageScaffold(
            child: Text('Opened ${state.pathParameters['id']}'),
          ),
        ),
        GoRoute(
          path: '/system/proxmox',
          builder: (_, _) =>
              const CupertinoPageScaffold(child: Text('Proxmox destination')),
        ),
      ],
    );
    addTearDown(() {
      router.dispose();
      container.dispose();
      unawaited(changes.close());
      visible.dispose();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: CupertinoApp.router(
          routerConfig: router,
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
        ),
      ),
    );
    await frames(tester);
  }
}

Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(Duration.zero);
  }
}

Future<void> show(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      300,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 40,
    );
  }
  await tester.ensureVisible(finder.first);
  await frames(tester);
}

void main() {
  testWidgets(
    'unknown and unitless values never display zero; parent and child remain independent',
    (tester) async {
      final harness = _Harness(
        state: _state([
          _meter('sensor.parent', value: 10),
          _meter('sensor.child', value: 4, parent: 'sensor.parent'),
          _meter('sensor.unitless', value: 7, unit: null),
          _meter('sensor.unknown', value: null),
        ]),
      );
      await harness.mount(tester);
      expect(find.text('10 kWh'), findsOneWidget);
      await show(tester, find.text('sensor.child'));
      expect(find.text('4 kWh'), findsOneWidget);
      expect(find.text('Included in: sensor.parent'), findsOneWidget);
      expect(find.text('14 kWh'), findsNothing);
      await show(tester, find.text('sensor.unitless'));
      expect(find.text('Unknown'), findsWidgets);
      expect(find.text('7 kWh'), findsNothing);
      await show(tester, find.text('sensor.unknown'));
      expect(find.text('0 kWh'), findsNothing);
      expect(harness.api.calls, isEmpty);
      expect(tester.takeException(), isNull);
      await harness.unmount(tester);
    },
  );
  testWidgets(
    'incomplete coverage and baseline evidence stay visible with daily disclosure',
    (tester) async {
      final harness = _Harness(
        state: _state([
          _meter(
            'sensor.partial',
            issues: {
              EnergyCoverageIssue.missingBaseline,
              EnergyCoverageIssue.hourlyGap,
            },
          ),
        ]),
      );
      await harness.mount(tester);
      await show(tester, find.text('sensor.partial'));
      expect(find.text('Incomplete coverage'), findsOneWidget);
      expect(
        find.text(
          'The preceding counter reading is missing; this change cannot be fully verified.',
        ),
        findsOneWidget,
      );
      final expand = find.byKey(
        const ValueKey('energy-meter-deviceConsumption:sensor.partial'),
      );
      await show(tester, expand);
      await tester.tap(expand);
      await frames(tester);
      expect(find.text('2026-09-05'), findsOneWidget);
      expect(find.text('3 kWh'), findsNWidgets(2));
      expect(harness.api.calls, isEmpty);
      await harness.unmount(tester);
    },
  );
  testWidgets(
    'loading and error hide retained energy rows and backend text; new account never exposes old rows',
    (tester) async {
      final harness = _Harness(
        state: _state([_meter('sensor.private_old_account')]),
      );
      await harness.mount(tester);
      expect(find.text('sensor.private_old_account'), findsOneWidget);
      harness.current = null;
      harness.container.invalidate(energyProvider);
      await frames(tester);
      expect(harness.container.read(energyProvider).isLoading, isTrue);
      expect(
        harness.container.read(energyProvider).value?.snapshot,
        isNotNull,
        reason: 'exercise retained Riverpod value',
      );
      expect(find.text('sensor.private_old_account'), findsNothing);
      harness.changes.addError(StateError('private-secret-backend-url'));
      await frames(tester);
      expect(find.text('sensor.private_old_account'), findsNothing);
      expect(find.textContaining('private-secret-backend-url'), findsNothing);
      (harness.container.read(connectionConfigProvider.notifier) as _Connection)
          .change();
      harness.changes.add(_state([_meter('sensor.new_account')]));
      await frames(tester);
      expect(find.text('sensor.new_account'), findsOneWidget);
      expect(find.text('sensor.private_old_account'), findsNothing);
      await harness.unmount(tester);
    },
  );
  testWidgets(
    'selected maintenance is default; all scope and entity navigation are explicit',
    (tester) async {
      final harness = _Harness(
        selected: [_item('sensor.selected')],
        all: [_item('sensor.selected'), _item('sensor.other')],
      );
      await harness.mount(tester);
      await show(tester, find.text('sensor.selected'));
      expect(find.text('sensor.other'), findsNothing);
      final all = find.byKey(const ValueKey('maintenance-scope-all'));
      await show(tester, all);
      await tester.tap(all);
      await frames(tester);
      await show(tester, find.text('sensor.other'));
      await tester.tap(find.text('sensor.other'));
      await tester.pumpAndSettle();
      expect(find.text('Opened sensor.other'), findsOneWidget);
      expect(harness.api.calls, isEmpty);
      await harness.unmount(tester);
    },
  );
  testWidgets(
    '5000 maintenance rows are built lazily, not as one large widget column',
    (tester) async {
      final harness = _Harness(
        selected: List.generate(5000, (i) => _item('sensor.lazy_$i')),
      );
      await harness.mount(tester);
      await show(tester, find.text('sensor.lazy_0'));
      final built = find.byWidgetPredicate(
        (widget) =>
            widget is Text && widget.data?.startsWith('sensor.lazy_') == true,
      );
      expect(built.evaluate().length, lessThan(30));
      expect(find.text('sensor.lazy_4999'), findsNothing);
      expect(tester.takeException(), isNull);
      await harness.unmount(tester);
    },
  );
  testWidgets(
    'Proxmox offline and unknown nodes never show stale or fabricated capacity',
    (tester) async {
      final harness = _Harness(
        nodes: [
          const ProxmoxNode(
            name: 'Offline node',
            status: 'offline',
            cpuFraction: .8,
            mem: 8,
            maxMem: 10,
          ),
          const ProxmoxNode(
            name: 'Unknown node',
            status: 'unknown',
            cpuFraction: .5,
          ),
          const ProxmoxNode(
            name: 'Online node',
            status: 'online',
            cpuFraction: 0,
            mem: 0,
            maxMem: 10,
          ),
        ],
      );
      await harness.mount(tester);
      await show(tester, find.text('Offline node'));
      expect(
        find.text('Node is offline; current capacity is unknown.'),
        findsOneWidget,
      );
      expect(find.text('80%'), findsNothing);
      await show(tester, find.text('Unknown node'));
      final unknownCard = find
          .ancestor(
            of: find.text('Unknown node'),
            matching: find.byType(Column),
          )
          .first;
      expect(
        find.descendant(
          of: unknownCard,
          matching: find.text('Node is offline; current capacity is unknown.'),
        ),
        findsNothing,
      );
      expect(find.text('50%'), findsNothing);
      await show(tester, find.text('Online node'));
      expect(find.text('0%'), findsNWidgets(2));
      expect(harness.nodeReads, 1);
      expect(tester.takeException(), isNull);
      await harness.unmount(tester);
    },
  );
  testWidgets(
    'Proxmox node cards are lazy and failed reload hides retained capacity',
    (tester) async {
      final harness = _Harness(
        nodes: List.generate(
          5000,
          (i) => ProxmoxNode(
            name: 'Private server $i',
            status: 'online',
            cpuFraction: .3,
          ),
        ),
      );
      await harness.mount(tester);
      await show(tester, find.text('Private server 0'));
      final built = find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            widget.data?.startsWith('Private server ') == true,
      );
      expect(built.evaluate().length, lessThan(30));
      expect(find.text('Private server 4999'), findsNothing);
      harness.nodeGate = Completer<List<ProxmoxNode>>();
      harness.container.invalidate(proxmoxNodesProvider);
      await frames(tester);
      expect(
        harness.container.read(proxmoxNodesProvider).value,
        isNotEmpty,
        reason: 'exercise retained node cache',
      );
      expect(find.text('Private server 0'), findsNothing);
      expect(find.text('30%'), findsNothing);
      harness.nodeGate!.completeError(StateError('private-node-endpoint'));
      await frames(tester);
      expect(find.text('Private server 0'), findsNothing);
      expect(find.textContaining('private-node-endpoint'), findsNothing);
      await harness.unmount(tester);
    },
  );

  for (final fixture in [
    (const Size(320, 900), 2.0),
    (const Size(1280, 1000), 1.6),
  ]) {
    testWidgets(
      'energy, maintenance and server capacity fit ${fixture.$1.width} at ${fixture.$2} text scale',
      (tester) async {
        final harness = _Harness(
          state: _state([
            _meter(
              'Very long energy meter label used by a household',
              issues: {
                EnergyCoverageIssue.missingBaseline,
                EnergyCoverageIssue.hourlyGap,
                EnergyCoverageIssue.boundaryLimited,
              },
            ),
          ]),
          selected: [_item('sensor.maintenance_fixture')],
          nodes: [
            const ProxmoxNode(
              name: 'Long server capacity node label',
              status: 'online',
              cpuFraction: .2,
              mem: 20,
              maxMem: 100,
            ),
          ],
        );
        await harness.mount(tester, size: fixture.$1, scale: fixture.$2);
        expect(tester.takeException(), isNull);
        await show(
          tester,
          find.byKey(
            const ValueKey(
              'energy-meter-deviceConsumption:Very long energy meter label used by a household',
            ),
          ),
        );
        await tester.tap(
          find.byKey(
            const ValueKey(
              'energy-meter-deviceConsumption:Very long energy meter label used by a household',
            ),
          ),
        );
        await frames(tester);
        expect(tester.takeException(), isNull);
        await show(tester, find.text('sensor.maintenance_fixture'));
        expect(tester.takeException(), isNull);
        await show(tester, find.text('Long server capacity node label'));
        expect(tester.takeException(), isNull);
        await harness.unmount(tester);
      },
    );
  }
  testWidgets(
    'real reader pauses offstage/background and preserves selected range while retained',
    (tester) async {
      final harness = _Harness(realReader: true);
      await harness.mount(tester);
      expect(
        harness.api.calls.where((value) => value == 'config'),
        hasLength(1),
      );
      await tester.tap(find.byKey(const ValueKey('energy-range-last7Days')));
      await frames(tester);
      final controller = harness.container.read(energyControllerProvider)!;
      expect(controller.range, EnergyRange.last7Days);
      expect(
        harness.api.calls.where((value) => value == 'config'),
        hasLength(2),
      );
      harness.visible.value = false;
      await frames(tester);
      await tester.pump(const Duration(minutes: 10));
      expect(
        harness.api.calls.where((value) => value == 'config'),
        hasLength(2),
      );
      harness.visible.value = true;
      await frames(tester);
      expect(
        harness.container.read(energyControllerProvider),
        same(controller),
      );
      expect(controller.range, EnergyRange.last7Days);
      expect(
        harness.api.calls.where((value) => value == 'config'),
        hasLength(3),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await frames(tester);
      await tester.pump(const Duration(minutes: 10));
      expect(
        harness.api.calls.where((value) => value == 'config'),
        hasLength(3),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await frames(tester);
      expect(controller.range, EnergyRange.last7Days);
      expect(
        harness.api.calls.where((value) => value == 'config'),
        hasLength(4),
      );
      await harness.unmount(tester);
    },
  );
}
