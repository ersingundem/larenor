import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/dashboard/presentation/tiles/proxmox_tile.dart';
import 'package:larenor/features/proxmox/data/models/proxmox_node.dart';
import 'package:larenor/features/proxmox/data/proxmox_config.dart';
import 'package:larenor/features/proxmox/presentation/proxmox_connect_screen.dart';
import 'package:larenor/features/proxmox/presentation/proxmox_nodes_screen.dart';
import 'package:larenor/features/proxmox/presentation/proxmox_node_detail_screen.dart';
import 'package:larenor/features/proxmox/presentation/widgets/proxmox_usage_bar.dart';
import 'package:larenor/features/proxmox/providers/proxmox_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

const config = ProxmoxConfig(
  host: 'pve.test',
  port: 8006,
  username: 'fixture',
  realm: 'pam',
  password: 'fixture',
  allowSelfSigned: false,
);

class _Connection extends ProxmoxConnection {
  @override
  Future<ProxmoxConfig?> build() async => config;
  void replace(AsyncValue<ProxmoxConfig?> value) => state = value;
}

class _Connect extends ProxmoxConnection {
  int calls = 0;
  bool? acceptedSelfSigned;
  final gate = Completer<void>();
  @override
  Future<ProxmoxConfig?> build() async => null;
  @override
  Future<void> signIn({
    required String host,
    required int port,
    required String username,
    required String realm,
    required String password,
    required bool allowSelfSigned,
  }) async {
    calls++;
    acceptedSelfSigned = allowSelfSigned;
    await gate.future;
  }
}

Widget app(Widget child) => CupertinoApp(
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);
Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump();
  }
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/network_info'),
          (_) async => null,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/network_info'),
          null,
        );
  });
  testWidgets(
    'usage bars distinguish unknown from real zero and reject non-finite fractions',
    (tester) async {
      await tester.pumpWidget(
        app(
          CupertinoPageScaffold(
            child: Column(
              children: [
                const ProxmoxUsageBar(label: 'missing', fraction: null),
                const ProxmoxUsageBar(label: 'zero', fraction: 0),
                const ProxmoxUsageBar(label: 'nan', fraction: double.nan),
                const ProxmoxUsageBar(label: 'invalid', fraction: 2),
              ],
            ),
          ),
        ),
      );
      expect(find.text('zero 0%'), findsOneWidget);
      expect(find.text('missing Unknown'), findsOneWidget);
      expect(find.text('nan Unknown'), findsOneWidget);
      expect(find.text('invalid Unknown'), findsOneWidget);
      expect(find.byType(FractionallySizedBox), findsOneWidget);
    },
  );
  testWidgets(
    'node overview builds lazily and clears prior rows during failed reload',
    (tester) async {
      var fail = false;
      final gate = Completer<List<ProxmoxNode>>();
      final container = ProviderContainer(
        overrides: [
          proxmoxConnectionProvider.overrideWith(_Connection.new),
          proxmoxNodesProvider.overrideWith((_) async {
            if (fail) return gate.future;
            return List.generate(
              5000,
              (i) => ProxmoxNode(name: 'node-$i', status: 'online'),
            );
          }),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: app(const ProxmoxNodesScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('node-0'), findsOneWidget);
      expect(find.byType(CupertinoListTile).evaluate().length, lessThan(25));
      fail = true;
      container.invalidate(proxmoxNodesProvider);
      await frames(tester);
      expect(find.text('node-0'), findsNothing);
      gate.completeError(StateError('private-token-error'));
      await tester.pumpAndSettle();
      expect(find.textContaining('private-token-error'), findsNothing);
      expect(find.text('node-0'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'tile hides retained account data, missing metrics stay unknown, hidden demand stops',
    (tester) async {
      var reads = 0, disposed = 0;
      final connection = _Connection();
      final visible = ValueNotifier(true);
      addTearDown(visible.dispose);
      final container = ProviderContainer(
        overrides: [
          proxmoxConnectionProvider.overrideWith(() => connection),
          proxmoxNodesProvider.overrideWith((ref) async {
            reads++;
            ref.onDispose(() => disposed++);
            return const [
              ProxmoxNode(
                name: 'old-private-node',
                status: 'online',
                cpuFraction: 0,
              ),
            ];
          }),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: app(
            ValueListenableBuilder(
              valueListenable: visible,
              builder: (_, value, _) => TickerMode(
                enabled: value,
                child: const Center(
                  child: SizedBox(
                    width: 360,
                    height: 220,
                    child: ProxmoxTile(
                      tile: TileConfig(
                        id: 'p',
                        width: 2,
                        height: 1,
                        type: TileType.proxmox,
                        x: 0,
                        y: 0,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('old-private-node · CPU 0% · RAM Unknown'),
        findsOneWidget,
      );
      expect(reads, 1);
      visible.value = false;
      await tester.pumpAndSettle();
      expect(disposed, 1);
      expect(find.textContaining('old-private-node'), findsNothing);
      visible.value = true;
      await tester.pumpAndSettle();
      expect(reads, 2);
      connection.replace(
        // Retained AsyncValue is a deliberate regression fixture.
        // ignore: invalid_use_of_internal_member
        const AsyncLoading<ProxmoxConfig?>().copyWithPrevious(
          const AsyncData(config),
        ),
      );
      await frames(tester);
      expect(find.textContaining('old-private-node'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'connection defaults to trusted TLS and double submission signs in once',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      tester.view.physicalSize = const Size(700, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final connection = _Connect();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [proxmoxConnectionProvider.overrideWith(() => connection)],
          child: app(const ProxmoxConnectScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<CupertinoSwitch>(find.byType(CupertinoSwitch)).value,
        isFalse,
      );
      final fields = find.byType(CupertinoTextField);
      await tester.enterText(fields.at(0), 'pve.test');
      await tester.enterText(fields.at(4), 'fixture-password');
      final button = tester.widget<CupertinoButton>(
        find.widgetWithText(CupertinoButton, 'Connect'),
      );
      button.onPressed!();
      button.onPressed!();
      await frames(tester);
      expect(connection.calls, 1);
      expect(connection.acceptedSelfSigned, isFalse);
      connection.gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(ProxmoxConnectScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'node route remains bound when the source row is hidden, and expires on account change',
    (tester) async {
      final connection = _Connection();
      final container = ProviderContainer(
        overrides: [
          proxmoxConnectionProvider.overrideWith(() => connection),
          proxmoxNodesProvider.overrideWith(
            (_) async => const [
              ProxmoxNode(name: 'pve-node', status: 'online'),
            ],
          ),
          proxmoxGuestsProvider('pve-node').overrideWith((_) async => []),
          proxmoxStoragesProvider('pve-node').overrideWith((_) async => []),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: app(const ProxmoxNodesScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('pve-node'));
      await tester.pumpAndSettle();
      expect(find.byType(ProxmoxNodeDetailScreen), findsOneWidget);
      expect(
        find.text(
          'The Proxmox connection changed. Close this screen and reopen the target.',
        ),
        findsNothing,
      );
      connection.replace(
        const AsyncData(
          ProxmoxConfig(
            host: 'new-pve.test',
            port: 8006,
            username: 'fixture',
            realm: 'pam',
            password: 'replacement',
            allowSelfSigned: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          'The Proxmox connection changed. Close this screen and reopen the target.',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
