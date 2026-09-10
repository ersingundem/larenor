import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/home_session_controller.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/core_proxmox/data/core_proxmox_providers.dart';
import 'package:larenor/features/core_proxmox/domain/core_proxmox_models.dart';
import 'package:larenor/features/core_proxmox/presentation/core_proxmox_screen.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/dashboard/presentation/tiles/proxmox_tile.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

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
  _Auth(this.contextValue)
    : super(endpoint: ServerEndpoint('https://core.invalid'));
  final ServerContext contextValue;
  ServerSession get session => ServerSession(
    endpoint: endpoint,
    accessToken: 'a' * 43,
    refreshToken: 'b' * 43,
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
    user: ServerUser(
      id: 'f' * 32,
      username: 'member',
      role: ServerRole.member,
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
}
