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
import 'package:larenor/core/window/window_policy_models.dart';
import 'package:larenor/core/window/window_policy_providers.dart';
import 'package:larenor/features/inventory/data/inventory_scanner.dart';
import 'package:larenor/features/inventory/presentation/inventory_route.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import 'inventory_models_test.dart';

final class MemorySource implements HomeSourcePersistence {
  HomeSource value = HomeSource.verifiedCore;
  @override
  Future<HomeSource> read() async => value;
  @override
  Future<void> write(HomeSource source) async => value = source;
}

final class MemorySessions implements ServerSessionPersistence {
  ServerSession? value;
  @override
  Future<ServerSession?> read() async => value;
  @override
  Future<void> write(ServerSession? session) async => value = session;
}

final class NoCamera implements InventoryScannerPlatform {
  @override
  InventoryScannerSession create() => throw StateError('camera not requested');
}

final class ClosingClient extends http.BaseClient {
  ClosingClient(this.inner);
  final http.Client inner;
  int closes = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      inner.send(request);
  @override
  void close() {
    closes++;
    inner.close();
  }
}

http.Response jsonResponse(Object value) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  testWidgets(
    'localized route retires pending read on exact home authority change',
    (tester) async {
      final loginClient = MockClient((request) async {
        if (request.url.path.endsWith('/auth/login')) {
          return jsonResponse({
            'accessToken': 'a' * 43,
            'refreshToken': 'b' * 43,
            'expiresIn': 3600,
            'user': {
              'id': '9' * 32,
              'username': 'Fixture',
              'role': 'admin',
              'mustChangePassword': false,
            },
          });
        }
        if (request.url.path.endsWith('/context')) {
          return jsonResponse({
            'schemaVersion': 1,
            'coreId': core,
            'homeId': home,
          });
        }
        throw StateError('unexpected account route ${request.url.path}');
      });
      final account = ServerAccountController(
        store: MemorySessions(),
        apiFactory: (endpoint) =>
            LarenorServerApi(endpoint: endpoint, client: loginClient),
      );
      await account.signIn(
        baseUrl: 'https://core.invalid',
        username: 'fixture',
        password: 'password',
        deviceName: 'tablet',
      );
      final source = MemorySource();
      final homeController = HomeSessionController(
        store: source,
        account: account,
      );
      await homeController.initialize();
      homeController.runtimeMounted(homeController.runtimeIdentity);

      final pending = Completer<http.Response>();
      final seen = Completer<void>();
      late ClosingClient inventoryClient;
      inventoryClient = ClosingClient(
        MockClient((request) {
          if (!seen.isCompleted) seen.complete();
          return pending.future;
        }),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            homeSessionControllerProvider.overrideWithValue(homeController),
            windowPolicySnapshotProvider.overrideWith((_) async* {
              yield const WindowPolicySnapshot(
                supported: false,
                isResumed: true,
                hasWindowFocus: true,
                reason: WindowRestrictionReason.unsupported,
              );
            }),
          ],
          child: AppInteractionScope(
            controller: homeController.interaction,
            child: CupertinoApp(
              locale: const Locale('tr'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: InventoryRoute(
                scannerPlatform: NoCamera(),
                apiFactory: (endpoint) => LarenorServerApi(
                  endpoint: endpoint,
                  client: inventoryClient,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Ev envanteri'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('inventory-manual-entry')),
        'larenor:inventory:v1:$core:$home:$itemId',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await seen.future.timeout(const Duration(seconds: 1));

      await homeController.choose(HomeSource.directLocal);
      await tester.pump();
      pending.complete(jsonResponse(itemResponse()));
      await tester.pumpAndSettle();

      expect(find.text('Kahve değirmeni'), findsNothing);
      expect(
        find.text(
          'Envanteri okumak için bu evin doğrulanmış Larenor Core bağlantısını kullanın.',
        ),
        findsOneWidget,
      );
      expect(inventoryClient.closes, 1);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      homeController.dispose();
      account.dispose();
    },
  );
}
