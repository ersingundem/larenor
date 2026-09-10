import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/core/home_session_controller.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/core/window/window_policy_models.dart';
import 'package:larenor/core/window/window_policy_providers.dart';
import 'package:larenor/features/core_proxmox/data/core_proxmox_providers.dart';
import 'package:larenor/features/core_proxmox/domain/core_proxmox_models.dart';
import 'package:larenor/features/core_proxmox/presentation/core_proxmox_screen.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/dashboard/presentation/tiles/proxmox_tile.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/settings/presentation/settings_gate_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Sessions implements ServerSessionPersistence {
  ServerSession? value;
  @override
  Future<ServerSession?> read() async => value;
  @override
  Future<void> write(ServerSession? value) async => this.value = value;
}

class _Source implements HomeSourcePersistence {
  @override
  Future<HomeSource> read() async => HomeSource.verifiedCore;
  @override
  Future<void> write(HomeSource value) async {}
}

class _Auth extends LarenorServerApi {
  _Auth(this.contextValue, {this.role = ServerRole.member})
    : super(endpoint: ServerEndpoint('https://core.invalid'));
  final ServerContext contextValue;
  final ServerRole role;
  ServerSession get session => ServerSession(
    endpoint: endpoint,
    accessToken: 'a' * 43,
    refreshToken: 'b' * 43,
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
    user: ServerUser(
      id: 'f' * 32,
      username: role == ServerRole.admin ? 'admin' : 'member',
      role: role,
      mustChangePassword: false,
    ),
  );
  @override
  Future<ServerSession> login({
    required String username,
    required String password,
    required String deviceName,
  }) async => session;
  @override
  Future<ServerSession> refresh(String token) async => session;
  @override
  Future<ServerContext> context(String token) async => contextValue;
  @override
  Future<ServerUser> me(String token) async => session.user;
  @override
  Future<void> logout(ServerSession session) async {}
}

CoreProxmoxSummary _summary() {
  final contract = jsonDecode(
    File('contracts/proxmox-resource.v1.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  return CoreProxmoxSummary.fromJson(contract['summary']);
}

Map<String, Object?> _targetPage(
  Map<String, dynamic> fixture, {
  String mode = 'ready',
}) {
  final resource = fixture['resource'] as Map<String, dynamic>;
  final ref = resource['ref'] as Map<String, dynamic>;
  final binding = fixture['binding'] as Map<String, dynamic>;
  final service = fixture['service'] as Map<String, dynamic>;
  Map<String, Object?> target(String id, int guestId) => {
    'schemaVersion': 1,
    'targetId': id,
    'installationId': service['id'],
    'node': 'pve-a',
    'guestKind': 'qemu',
    'guestId': guestId,
    'currentState': 'running',
    'statusRevision': 9,
    'allowedCommands': mode == 'ready'
        ? ['shutdown', 'stop', 'reboot', 'suspend']
        : <String>[],
    'capabilityReady': mode == 'ready',
  };
  final targets = mode == 'ambiguous'
      ? [target('7' * 32, 101), target('8' * 32, 102)]
      : [target('7' * 32, 101)];
  return {
    'schemaVersion': 1,
    'scope': {
      'schemaVersion': 1,
      'coreId': ref['coreId'],
      'homeId': ref['homeId'],
    },
    'resourceId': ref['id'],
    'userRevision': 6,
    'resourceRevision': resource['revision'],
    'aclRevision': resource['aclRevision'],
    'bindingId': binding['id'],
    'bindingRevision': binding['revision'],
    'serviceId': service['id'],
    'serviceRevision': service['revision'],
    'snapshot': '9' * 64,
    'targets': targets,
    'nextAfter': null,
  };
}

final class _TileHarness {
  const _TileHarness(this.paths, this.account, this.home);
  final List<String> paths;
  final ServerAccountController account;
  final HomeSessionController home;
}

Future<_TileHarness> _mountCoreTile(
  WidgetTester tester, {
  required Future<http.Response> Function(
    http.Request request,
    Map<String, dynamic> fixture,
  )
  respond,
  ServerRole role = ServerRole.admin,
  Size size = const Size(600, 900),
  double scale = 1,
}) async {
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues({'settings_pin': '1234'});
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final fixture = jsonDecode(
    File('contracts/proxmox-resource.v1.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final context = ServerContext.fromJson(fixture['context']);
  final account = ServerAccountController(
    store: _Sessions(),
    apiFactory: (_) => _Auth(context, role: role),
  );
  final home = HomeSessionController(store: _Source(), account: account);
  await account.initialize();
  await home.initialize();
  await account.signIn(
    baseUrl: 'https://core.invalid',
    username: role == ServerRole.admin ? 'admin' : 'member',
    password: 'password',
    deviceName: 'tablet',
  );
  home.runtimeMounted(home.runtimeIdentity);
  final paths = <String>[];
  LarenorServerApi transport(ServerEndpoint endpoint) => LarenorServerApi(
    endpoint: endpoint,
    client: MockClient((request) {
      paths.add('${request.method} ${request.url.path}');
      return respond(request, fixture);
    }),
  );
  final source = fixture['resource'] as Map<String, dynamic>;
  final resource = {
    ...source,
    'permissions': {'read': true, 'write': role == ServerRole.admin},
  };
  fixture['resource'] = resource;
  final id = (resource['ref'] as Map<String, dynamic>)['id'] as String;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        homeSessionControllerProvider.overrideWithValue(home),
        coreProxmoxApiFactoryProvider.overrideWithValue(transport),
        windowPolicySnapshotProvider.overrideWith((_) async* {
          yield const WindowPolicySnapshot(
            supported: true,
            isResumed: true,
            hasWindowFocus: true,
            reason: WindowRestrictionReason.none,
          );
        }),
      ],
      child: CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (_, child) => MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(scale),
          ),
          child: AppInteractionScope(
            controller: home.interaction,
            child: child!,
          ),
        ),
        home: CupertinoPageScaffold(
          child: SizedBox(
            width: size.width,
            height: 360,
            child: ProxmoxTile(
              tile: TileConfig(
                id: 'tile',
                type: TileType.proxmox,
                x: 0,
                y: 0,
                width: 3,
                height: 2,
                entityId: id,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  for (var index = 0; index < 30; index++) {
    await tester.pump();
  }
  addTearDown(() {
    home.dispose();
    account.dispose();
  });
  return _TileHarness(paths, account, home);
}

Widget _app({Locale locale = const Locale('en'), double scale = 1}) =>
    CupertinoApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(900, 700),
          textScaler: TextScaler.linear(scale),
        ),
        child: CupertinoPageScaffold(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: CoreProxmoxSummaryPanel(summary: _summary()),
          ),
        ),
      ),
    );

void main() {
  testWidgets('tablet summary exposes typed status and metrics to TalkBack', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('core-proxmox-node-pve-a')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('core-proxmox-guest-qemu-101')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('core-proxmox-storage-pve-a-local-lvm')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp(r'pve-a, Online, CPU: 25%')),
      findsOneWidget,
    );
    expect(find.textContaining('QEMU VM #101'), findsOneWidget);
    expect(find.textContaining('LXC container #102'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('two-times Turkish text falls back to one readable column', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(locale: const Locale('tr'), scale: 2));
    await tester.pumpAndSettle();

    expect(find.text('Çevrimiçi'), findsOneWidget);
    expect(find.textContaining('LXC konteyneri #102'), findsOneWidget);
    final first = tester.getSize(
      find.byKey(const ValueKey('core-proxmox-node-pve-a')),
    );
    expect(first.width, greaterThan(800));
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty backup and snapshot state stays explicit at 2x text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final raw = jsonDecode(
      File('contracts/proxmox-resource.v1.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final summary =
        jsonDecode(jsonEncode(raw['summary'])) as Map<String, dynamic>;
    final protection = summary['protection'] as Map<String, dynamic>;
    protection['state'] = 'empty';
    protection['latestBackup'] = null;
    for (final snapshot in protection['snapshots'] as List) {
      (snapshot as Map<String, dynamic>)
        ..['snapshotCount'] = 0
        ..['latestAt'] = null;
    }
    final retention = summary['retention'] as Map<String, dynamic>;
    retention['protectedGuestCount'] = 0;
    retention['warnings'] = [
      {
        'kind': 'restore_point_missing',
        'severity': 'attention',
        'affectedCount': 2,
        'observedPercent': null,
        'ageSeconds': null,
      },
    ];
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(600, 900),
            textScaler: TextScaler.linear(2),
          ),
          child: CupertinoPageScaffold(
            child: SingleChildScrollView(
              child: CoreProxmoxDetailExplorer(
                summary: CoreProxmoxSummary.fromJson(summary),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No backup record'), findsOneWidget);
    expect(find.text('No snapshots'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide detail groups, filters and searches read-only telemetry', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: CupertinoPageScaffold(
          child: SingleChildScrollView(
            child: CoreProxmoxDetailExplorer(summary: _summary()),
          ),
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey('core-proxmox-master-detail')),
      findsOneWidget,
    );
    expect(find.text('Nodes'), findsWidgets);
    expect(find.text('Virtual machines & containers'), findsWidgets);
    expect(find.text('Storage'), findsWidgets);
    expect(find.text('Recent tasks'), findsWidgets);
    expect(find.textContaining('vzdump'), findsWidgets);
    expect(find.textContaining('Succeeded'), findsWidgets);
    expect(find.text('Backup retention'), findsWidgets);
    expect(find.text('Missing restore point'), findsWidgets);
    expect(find.textContaining('root@pam'), findsNothing);
    expect(find.text('Capacity & maintenance'), findsWidgets);
    expect(find.text('Node offline'), findsWidgets);
    expect(find.text('Recent task failed'), findsWidgets);
    expect(find.textContaining('private'), findsNothing);
    expect(find.text('Backup & snapshots'), findsWidgets);
    expect(find.text('Latest backup'), findsWidgets);
    expect(find.textContaining('Snapshots · QEMU #101'), findsWidgets);
    expect(find.textContaining('Succeeded'), findsWidgets);
    expect(
      tester
          .widget<CupertinoButton>(
            find.byKey(const ValueKey('core-proxmox-detail-guest-lxc-102')),
          )
          .minimumSize
          ?.height,
      greaterThanOrEqualTo(48),
    );
    expect(
      find.bySemanticsLabel(RegExp('Virtual machines & containers')),
      findsWidgets,
    );
    await tester.enterText(
      find.byKey(const ValueKey('core-proxmox-detail-search')),
      'DNS',
    );
    await tester.pump();
    expect(find.textContaining('LXC container #102'), findsWidgets);
    expect(find.textContaining('QEMU VM #101'), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('core-proxmox-detail-search')),
      '',
    );
    await tester.pump();
    final storageFilter = find.byKey(
      const ValueKey('core-proxmox-filter-storage'),
    );
    final storageLabel = find.descendant(
      of: storageFilter,
      matching: find.text('Storage'),
    );
    Focus.of(tester.element(storageLabel)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.textContaining('local-lvm'), findsWidgets);
    expect(find.textContaining('QEMU VM #101'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('core-proxmox-filter-tasks')));
    await tester.pump();
    expect(find.textContaining('vzdump'), findsWidgets);
    expect(find.textContaining('local-lvm'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey('core-proxmox-filter-maintenance')),
    );
    await tester.pump();
    expect(find.text('Node offline'), findsWidgets);
    expect(find.text('Recent task failed'), findsWidgets);
    expect(find.textContaining('vzdump'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey('core-proxmox-filter-protection')),
    );
    await tester.pump();
    expect(find.text('Latest backup'), findsWidgets);
    expect(find.textContaining('Snapshots · QEMU #101'), findsWidgets);
    expect(find.text('Node offline'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey('core-proxmox-filter-retention')),
    );
    await tester.pump();
    expect(find.text('Backup retention'), findsWidgets);
    expect(find.text('Missing restore point'), findsWidgets);
    expect(find.textContaining('current sample'), findsWidgets);
    expect(find.text('Latest backup'), findsNothing);
    for (final key in [
      'core-proxmox-filter-all',
      'core-proxmox-filter-nodes',
      'core-proxmox-filter-guests',
      'core-proxmox-filter-storage',
      'core-proxmox-filter-maintenance',
      'core-proxmox-filter-protection',
      'core-proxmox-filter-retention',
      'core-proxmox-filter-tasks',
    ]) {
      final button = tester.widget<CupertinoButton>(find.byKey(ValueKey(key)));
      expect(button.minimumSize?.height ?? 0, greaterThanOrEqualTo(48));
    }
    semantics.dispose();
  });

  testWidgets('verified Core dashboard tile reads the selected resource only', (
    tester,
  ) async {
    final f = jsonDecode(
      File('contracts/proxmox-resource.v1.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final context = ServerContext.fromJson(f['context']);
    final account = ServerAccountController(
      store: _Sessions(),
      apiFactory: (_) => _Auth(context),
    );
    final home = HomeSessionController(store: _Source(), account: account);
    await account.initialize();
    await home.initialize();
    await account.signIn(
      baseUrl: 'https://core.invalid',
      username: 'member',
      password: 'password',
      deviceName: 'tablet',
    );
    home.runtimeMounted(home.runtimeIdentity);
    addTearDown(() {
      home.dispose();
      account.dispose();
    });
    final paths = <String>[];
    LarenorServerApi transport(ServerEndpoint endpoint) => LarenorServerApi(
      endpoint: endpoint,
      client: MockClient((request) async {
        paths.add(request.url.path);
        final body = request.url.path.endsWith('/snapshot')
            ? {'snapshot': f['snapshot']}
            : {'record': f['resource']};
        return http.Response(
          jsonEncode(body),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final target = f['resource'] as Map<String, dynamic>;
    final id = (target['ref'] as Map<String, dynamic>)['id'] as String;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeSessionControllerProvider.overrideWithValue(home),
          coreProxmoxApiFactoryProvider.overrideWithValue(transport),
        ],
        child: CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: CupertinoPageScaffold(
            child: Center(
              child: SizedBox(
                width: 500,
                height: 260,
                child: ProxmoxTile(
                  tile: TileConfig(
                    id: 'tile',
                    type: TileType.proxmox,
                    x: 0,
                    y: 0,
                    width: 3,
                    height: 2,
                    entityId: id,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump();
    }

    expect(find.textContaining('pve-a'), findsOneWidget);
    expect(
      paths.where((path) => path.contains('/home-resources/')),
      hasLength(2),
    );
    expect(paths.where((path) => path.endsWith('/snapshot')), hasLength(1));

    await account.signOut();
    await tester.pump();
    expect(find.textContaining('pve-a'), findsNothing);
    expect(
      find.text('A verified, unlocked Core session is required.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(600, 900), const Size(1280, 900)]) {
    testWidgets(
      'admin ${size.width.toInt()}px 2x tile opens detail then PIN power gate',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final harness = await _mountCoreTile(
          tester,
          size: size,
          scale: 2,
          respond: (request, fixture) async {
            if (request.url.path.endsWith('/targets')) {
              return http.Response(
                jsonEncode(_targetPage(fixture)),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            final body = request.url.path.endsWith('/snapshot')
                ? {'snapshot': fixture['snapshot']}
                : {'record': fixture['resource']};
            return http.Response(
              jsonEncode(body),
              200,
              headers: {'content-type': 'application/json'},
            );
          },
        );
        expect(find.textContaining('Uptime 1d'), findsOneWidget);
        expect(find.textContaining('RAM 25%'), findsOneWidget);
        expect(find.textContaining('Storage 50%'), findsOneWidget);
        expect(find.textContaining('QEMU #101 · Running'), findsOneWidget);
        expect(find.textContaining('Power commands ready'), findsOneWidget);
        final button = find.byType(CupertinoButton).first;
        expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
        expect(
          find.bySemanticsLabel(RegExp('Power commands ready')),
          findsOneWidget,
        );
        await tester.tap(find.byType(CupertinoButton).first);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('core-proxmox-detail-search')),
          findsOneWidget,
        );
        final refresh = find.byType(
          CupertinoSliverRefreshControl,
          skipOffstage: false,
        );
        expect(refresh, findsOneWidget);
        final snapshotReads = harness.paths
            .where((path) => path.endsWith('/snapshot'))
            .length;
        await tester
            .widget<CupertinoSliverRefreshControl>(refresh)
            .onRefresh!();
        await tester.pumpAndSettle();
        expect(
          harness.paths.where((path) => path.endsWith('/snapshot')).length,
          snapshotReads + 1,
        );
        final power = find.byKey(const ValueKey('core-proxmox-power-open'));
        await tester.ensureVisible(power);
        await tester.tap(power);
        await tester.pumpAndSettle();
        expect(find.byType(SettingsGateScreen), findsOneWidget);
        expect(find.text('Unlock'), findsOneWidget);
        await tester.enterText(find.byType(CupertinoTextField), '1234');
        await tester.tap(find.text('Unlock'));
        await tester.pumpAndSettle();
        expect(find.text('Power controls'), findsWidgets);
        expect(
          harness.paths.where((path) => path.startsWith('POST ')),
          isEmpty,
        );
        semantics.dispose();
      },
    );
  }

  testWidgets('ambiguous discovery is explicit and only tap-refreshes once', (
    tester,
  ) async {
    final harness = await _mountCoreTile(
      tester,
      respond: (request, fixture) async {
        final body = request.url.path.endsWith('/targets')
            ? _targetPage(fixture, mode: 'ambiguous')
            : request.url.path.endsWith('/snapshot')
            ? {'snapshot': fixture['snapshot']}
            : {'record': fixture['resource']};
        return http.Response(
          jsonEncode(body),
          200,
          headers: {'content-type': 'application/json'},
        );
      },
    );
    expect(find.textContaining('Multiple guests'), findsOneWidget);
    await tester.tap(find.byType(CupertinoButton).first);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('core-proxmox-detail-search')),
      findsOneWidget,
    );
    expect(find.textContaining('Multiple guests'), findsOneWidget);
    final before = harness.paths
        .where((path) => path.endsWith('/targets'))
        .length;
    final refresh = find.byKey(const ValueKey('core-proxmox-power-refresh'));
    await tester.ensureVisible(refresh);
    await tester.tap(refresh);
    await tester.pump();
    final after = harness.paths
        .where((path) => path.endsWith('/targets'))
        .length;
    expect(after, before + 1);
    await tester.pump(const Duration(seconds: 30));
    expect(
      harness.paths.where((path) => path.endsWith('/targets')).length,
      after,
    );
    expect(harness.paths.where((path) => path.startsWith('POST ')), isEmpty);
  });

  testWidgets(
    'offline and schema drift stay visible without command mutation',
    (tester) async {
      var discovery = 0;
      final harness = await _mountCoreTile(
        tester,
        respond: (request, fixture) async {
          if (request.url.path.endsWith('/targets')) {
            discovery++;
            if (discovery == 1) {
              return http.Response(
                jsonEncode({
                  'error': {'code': 'server_unavailable'},
                }),
                503,
                headers: {'content-type': 'application/json'},
              );
            }
            if (discovery > 2) {
              return http.Response(
                jsonEncode({
                  'error': {'code': 'revision_conflict'},
                }),
                409,
                headers: {'content-type': 'application/json'},
              );
            }
            return http.Response(
              jsonEncode({..._targetPage(fixture), 'host': 'private.invalid'}),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          final body = request.url.path.endsWith('/snapshot')
              ? {'snapshot': fixture['snapshot']}
              : {'record': fixture['resource']};
          return http.Response(
            jsonEncode(body),
            200,
            headers: {'content-type': 'application/json'},
          );
        },
      );
      expect(find.textContaining('offline'), findsOneWidget);
      await tester.tap(find.byType(CupertinoButton).first);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('core-proxmox-detail-search')),
        findsOneWidget,
      );
      expect(find.textContaining('could not be verified'), findsOneWidget);
      final refresh = find.byKey(const ValueKey('core-proxmox-power-refresh'));
      await tester.ensureVisible(refresh);
      await tester.tap(refresh);
      await tester.pumpAndSettle();
      expect(find.textContaining('Target details changed'), findsOneWidget);
      expect(harness.paths.where((path) => path.startsWith('POST ')), isEmpty);
    },
  );

  testWidgets('member and backgrounded admin never retain command readiness', (
    tester,
  ) async {
    final member = await _mountCoreTile(
      tester,
      role: ServerRole.member,
      respond: (request, fixture) async {
        final body = request.url.path.endsWith('/snapshot')
            ? {'snapshot': fixture['snapshot']}
            : {'record': fixture['resource']};
        return http.Response(
          jsonEncode(body),
          200,
          headers: {'content-type': 'application/json'},
        );
      },
    );
    expect(find.textContaining('Read-only summary'), findsOneWidget);
    expect(member.paths.where((path) => path.endsWith('/targets')), isEmpty);

    await tester.pumpWidget(const SizedBox());
    final pending = Completer<http.Response>();
    final admin = await _mountCoreTile(
      tester,
      respond: (request, fixture) async {
        if (request.url.path.endsWith('/targets')) return pending.future;
        final body = request.url.path.endsWith('/snapshot')
            ? {'snapshot': fixture['snapshot']}
            : {'record': fixture['resource']};
        return http.Response(
          jsonEncode(body),
          200,
          headers: {'content-type': 'application/json'},
        );
      },
    );
    expect(find.textContaining('Verifying power target'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await admin.account.signOut();
    pending.complete(
      http.Response(
        jsonEncode(
          _targetPage(
            jsonDecode(
              File('contracts/proxmox-resource.v1.json').readAsStringSync(),
            ) as Map<String, dynamic>,
          ),
        ),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    await tester.pump();
    expect(find.textContaining('Power commands ready'), findsNothing);
    expect(admin.paths.where((path) => path.startsWith('POST ')), isEmpty);
  });
}
