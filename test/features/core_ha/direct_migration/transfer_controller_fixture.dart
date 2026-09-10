import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/home_session_controller.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/core_ha/data/core_ha_providers.dart';
import 'package:larenor/features/core_ha/direct_migration/transfer_controller.dart';
import 'package:larenor/features/core_ha/direct_migration/transfer_providers.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core_ha_controller_fixture.dart' show HaHarness, settle;
import '../core_ha_api_test.dart' show response;
import '../core_ha_models_test.dart' show target, resourceJson, scopeJson;
import 'transfer_api_test.dart' show transferPreviewJson, transferReceiptJson;
import 'transfer_credentials_test.dart' show TransferPlatform;

class TransferHarness {
  final auth = HaHarness(), platform = TransferPlatform();
  late final owner = CoreHaTransferOwner(
    isCurrent: () => auth.pin && auth.route,
    interaction: auth.interaction,
  );
  late ProviderContainer container;
  CoreHaTransferController? controller;
  final requests = <http.Request>[];
  Future<http.Response> Function(http.Request)? reply;
  late FlutterSecureStoragePlatform oldPlatform;
  bool bound = false;
  Duration elapsed = Duration.zero;
  final layout = const DashboardLayout(
    rooms: [
      DashboardRoom(
        id: 'room',
        name: 'Local room',
        entityIds: ['switch.reading_lamp', 'scene.evening', 'script.evening'],
      ),
    ],
  );
  Future<http.Response> handle(http.Request r) async {
    requests.add(r);
    if (reply != null) return reply!(r);
    if (r.url.path.endsWith('/${target().context.homeId}')) {
      return response({
        'scope': scopeJson(),
        'userRevision': 7,
        'entries': [resourceJson()],
        'snapshot': 'a' * 64,
        'nextAfter': null,
      });
    }
    if (r.url.path.contains('/home-resources/')) {
      return response({'record': resourceJson()});
    }
    if (r.url.path.endsWith('/binding')) {
      return response({
        'error': {'code': 'not_found'},
      }, 404);
    }
    if (r.method == 'DELETE') return response(null, 204);
    if (r.url.path.endsWith('/preview')) {
      return response({
        'preview': transferPreviewJson(name: 'Home Assistant'),
      }, 201);
    }
    if (r.url.path.endsWith('/confirm')) {
      bound = true;
      return response({
        'receipt': transferReceiptJson(name: 'Home Assistant'),
      }, 201);
    }
    if (r.url.path.contains('/results/')) {
      return response({'receipt': transferReceiptJson(name: 'Home Assistant')});
    }
    throw StateError('Unexpected fixture route');
  }

  Future<void> mount(
    WidgetTester tester, {
    HomeSource source = HomeSource.directLocal,
  }) async {
    SharedPreferences.setMockInitialValues({
      'dashboard_layout': jsonEncode(layout.toJson()),
    });
    oldPlatform = FlutterSecureStoragePlatform.instance;
    FlutterSecureStoragePlatform.instance = MethodChannelFlutterSecureStorage();
    platform.values['ha_base_url'] = 'http://synthetic.invalid';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          platform.handle,
        );
    auth.context = target().context;
    auth.source.value = source;
    await auth.account.initialize();
    await auth.home.initialize();
    await auth.login();
    auth.home.runtimeMounted(auth.home.runtimeIdentity);
    container = ProviderContainer(
      overrides: [
        homeSessionControllerProvider.overrideWithValue(auth.home),
        coreHaClockProvider.overrideWithValue(() => auth.now),
        coreHaMonotonicProvider.overrideWithValue(() => elapsed),
        coreHaRequestIdProvider.overrideWithValue(() => '7' * 32),
        coreHaApiFactoryProvider.overrideWithValue(
          (endpoint) =>
              LarenorServerApi(endpoint: endpoint, client: MockClient(handle)),
        ),
      ],
      retry: (_, _) => null,
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: CupertinoApp(home: TransferProbe(h: this)),
      ),
    );
    await settle(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      owner.dispose();
      auth.interaction.dispose();
      auth.home.dispose();
      auth.account.dispose();
      FlutterSecureStoragePlatform.instance = oldPlatform;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            null,
          );
      await settle(tester);
    });
  }
}

class TransferProbe extends ConsumerStatefulWidget {
  const TransferProbe({super.key, required this.h});
  final TransferHarness h;
  @override
  ConsumerState<TransferProbe> createState() => _TransferProbeState();
}

class _TransferProbeState extends ConsumerState<TransferProbe> {
  @override
  void dispose() {
    widget.h.owner.retire();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    widget.h.controller = ref.watch(
      coreHaTransferControllerProvider(widget.h.owner),
    );
    return const SizedBox();
  }
}
