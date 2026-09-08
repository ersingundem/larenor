import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/core/home_session_controller.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/core_ha/data/core_ha_controller.dart';
import 'package:larenor/features/core_ha/data/core_ha_providers.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import 'dart:io';
import 'core_ha_api_test.dart' show serviceJson;

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

http.Response jsonResponse(Object? data, [int status = 200]) => status == 204
    ? http.Response('', 204)
    : http.Response(
        jsonEncode(data),
        status,
        headers: {'content-type': 'application/json'},
      );

class HaStore implements ServerSessionPersistence {
  ServerSession? value;
  @override
  Future<ServerSession?> read() async => value;
  @override
  Future<void> write(ServerSession? value) async {
    this.value = value;
  }
}

class HaSource implements HomeSourcePersistence {
  HomeSource value = HomeSource.verifiedCore;
  @override
  Future<HomeSource> read() async => value;
  @override
  Future<void> write(HomeSource value) async {
    this.value = value;
  }
}

class HaAuth extends LarenorServerApi {
  HaAuth(this.h)
    : super(
        endpoint: ServerEndpoint('https://synthetic.invalid'),
        client: MockClient((_) async => jsonResponse(null, 500)),
      );
  final HaHarness h;
  Completer<ServerContext>? pendingContext;
  int refreshes = 0;
  ServerSession fresh() => ServerSession(
    endpoint: endpoint,
    accessToken: 'access-$refreshes',
    refreshToken: 'refresh-$refreshes',
    expiresAt: h.now.add(const Duration(hours: 1)),
    user: ServerUser(
      id: h.userId,
      username: 'Fixture',
      role: h.role,
      mustChangePassword: h.mustChangePassword,
    ),
  );
  @override
  Future<ServerSession> login({
    required String username,
    required String password,
    required String deviceName,
  }) async => fresh();
  @override
  Future<ServerSession> refresh(String token) async {
    refreshes++;
    return fresh();
  }

  @override
  Future<ServerContext> context(String token) async =>
      pendingContext == null ? h.context : pendingContext!.future;
  @override
  Future<ServerUser> me(String token) async => fresh().user;
  @override
  Future<void> logout(ServerSession session) async {}
}

class HaHarness {
  final f = jsonDecode(File('contracts/home-assistant.v1.json').readAsStringSync()) as Map<String, dynamic>;
  DateTime now = DateTime.utc(2026, 9, 6);
  late ServerContext context = ServerContext.fromJson(f['context']);
  String userId = 'f' * 32;
  ServerRole role = ServerRole.admin;
  bool mustChangePassword = false,
      pin = true,
      route = true,
      throwsOwner = false;
  final store = HaStore(),
      source = HaSource(),
      interaction = AppInteractionController();
  late final auth = HaAuth(this);
  late final account = ServerAccountController(
    store: store,
    apiFactory: (_) => auth,
    clock: () => now,
  );
  late final home = HomeSessionController(store: source, account: account);
  bool Function()? current;
  final requests = <http.Request>[];
  int transports = 0, closes = 0;
  String snapshotStep = 'snapshotOff';
  bool bound = false;
  Duration elapsed = Duration.zero;
  Future<http.Response> Function(http.Request)? reply;
  late final owner = CoreHaOwner(
    isCurrent: () => throwsOwner
        ? throw StateError('private')
        : pin && route && (current?.call() ?? true),
    interaction: interaction,
  );
  late final container = makeContainer();
  CoreHaController? list;
  late final HomeResourceRecord target = HomeResourceRecord.fromJson(
    f['resource'],
    expectedContext: context,
  );
  ProviderContainer makeContainer() => ProviderContainer(
    overrides: [
      homeSessionControllerProvider.overrideWithValue(home),
      coreHaClockProvider.overrideWithValue(() => now),
      coreHaMonotonicProvider.overrideWithValue(() => elapsed),
      coreHaApiFactoryProvider.overrideWithValue((endpoint) {
        transports++;
        return LarenorServerApi(
          endpoint: endpoint,
          client: TrackedClient((request) async {
            requests.add(request);
            if (reply != null) return reply!(request);
            final path = request.url.path;
            if (path.contains('/home-resources/')) return jsonResponse({'record': f['resource']});
            if (path.endsWith('/services')) return jsonResponse({'services': [{...serviceJson(), 'id': f['preview']['body']['serviceId']}]});
            final step = path.endsWith('/snapshot') ? snapshotStep
                : path.endsWith('/binding') ? (bound ? 'binding' : 'unbound')
                : path.endsWith('/binding-preview') ? 'preview'
                : path.endsWith('/binding-confirm') ? 'confirm' : 'cancel';
            if (step == 'confirm') bound = true;
            return jsonResponse(f[step]['response'], f[step]['status'] as int);
          }, () => closes++),
        );
      }),
    ],
  );
  Future<void> login() => account.signIn(
    baseUrl: 'https://synthetic.invalid',
    username: 'fixture',
    password: 'synthetic',
    deviceName: 'fixture',
  );
  Future<void> mount(
    WidgetTester tester, {
    bool admin = true,
    Key? key,
  }) async {
    await account.initialize();
    await home.initialize();
    await login();
    home.runtimeMounted(home.runtimeIdentity);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: CupertinoApp(
          home: HaProbe(
            key: key,
            h: this,
            admin: admin,
          ),
        ),
      ),
    );
    await settle(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      owner.dispose();
      interaction.dispose();
      home.dispose();
      account.dispose();
      await settle(tester);
    });
  }
}

class TrackedClient extends MockClient {
  TrackedClient(super.fn, this.closed);
  final void Function() closed;
  @override
  void close() {
    closed();
    super.close();
  }
}

class HaProbe extends ConsumerStatefulWidget {
  const HaProbe({
    super.key,
    required this.h,
    this.admin = true,
  });
  final HaHarness h;
  final bool admin;
  @override
  ConsumerState<HaProbe> createState() => HaProbeState();
}

class HaProbeState extends ConsumerState<HaProbe> {
  @override
  void dispose() {
    widget.h.owner.retire();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.h;
    final c = ref.watch(coreHaControllerProvider((owner: h.owner, target: h.target, admin: widget.admin)));
    h.list = c;
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) c.setVisible(true); });
    return const SizedBox();
  }
}
