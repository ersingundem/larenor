import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// Real pinned secure-storage channel; no provider/store override.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/core/direct_home_access.dart';
import 'package:larenor/features/media/arr/presentation/widgets/arr_connect_form.dart';
import 'package:larenor/features/settings/presentation/settings_gate_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/discovery/lan_discovery_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/direct_arr_credentials_test.dart'
    show arrServices, holdArr;
import '../../../core/direct_api_key_credentials_test.dart'
    show ApiKeyPlatform, apiKeyServices, holdApiKey;
import '../../../core/direct_home_routines_test.dart' show routinesHome;
import '../api_key/direct_api_key_recovery_test.dart'
    show pumpApiFrames, tapApiText;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ApiKeyPlatform secure;
  late FlutterSecureStoragePlatform previous;
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const wifi = MethodChannel('dev.fluttercommunity.plus/network_info');
  var wifiQueries = 0;
  setUp(() {
    secure = ApiKeyPlatform();
    for (final name in arrServices) {
      secure.values['${name}_base_url'] = 'https://old.invalid';
      secure.values['${name}_api_key'] = 'synthetic-old-key';
    }
    secure.values['settings_pin'] = '2468';
    previous = FlutterSecureStoragePlatform.instance;
    FlutterSecureStoragePlatform.instance = MethodChannelFlutterSecureStorage();
    SharedPreferences.setMockInitialValues({});
    wifiQueries = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, secure.handle);
    messenger.setMockMethodCallHandler(wifi, (_) async {
      wifiQueries++;
      return null;
    });
  });
  tearDown(() {
    FlutterSecureStoragePlatform.instance = previous;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(wifi, null);
  });
  for (final name in [...arrServices, ...apiKeyServices]) {
    for (final recovery in ['clear', 'connect']) {
      testWidgets(
        '$name lost final marker ACK stays unknown through actual PIN and explicit $recovery',
        (tester) async {
          final marker = '${name}_connection_pending_v1';
          secure.values[marker] = '1';
          final (c, _) = await routinesHome('direct');
          final connection = arrServices.contains(name)
              ? holdArr(c, name)
              : holdApiKey(c, name);
          final interaction = AppInteractionController();
          addTearDown(interaction.dispose);
          tester.view.physicalSize = const Size(600, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          var requests = 0, lost = false;
          secure.afterEffect = (call) async {
            if (!lost &&
                call.method == 'delete' &&
                (call.arguments as Map)['key'] == marker) {
              lost = true;
              throw PlatformException(
                code: 'private-effect',
                message: 'private-storage-sentinel',
              );
            }
          };
          await http.runWithClient(
            () async {
              try {
                await tester.pumpWidget(
                  UncontrolledProviderScope(
                    container: c,
                    child: CupertinoApp(
                      locale: const Locale('en'),
                      localizationsDelegates:
                          AppLocalizations.localizationsDelegates,
                      supportedLocales: AppLocalizations.supportedLocales,
                      builder: (_, child) => AppInteractionScope(
                        controller: interaction,
                        child: child!,
                      ),
                      home: const SettingsGateScreen(),
                    ),
                  ),
                );
                await pumpApiFrames(tester);
                expect(find.byType(ArrConnectForm), findsNothing);
                await tester.enterText(find.byType(CupertinoTextField), '2468');
                for (final label in [
                  'Unlock',
                  'Integrations',
                  'Manage Integrations',
                  '${name[0].toUpperCase()}${name.substring(1)}',
                ]) {
                  await tapApiText(tester, label);
                }
                expect(find.byType(ArrConnectForm), findsOneWidget);
                expect(find.byType(LanDiscoverySection), findsNothing);
                expect(wifiQueries, 0);
                await tester.enterText(
                  find.byType(CupertinoTextFormFieldRow).at(0),
                  'https://new.invalid',
                );
                await tester.enterText(
                  find.byType(CupertinoTextFormFieldRow).at(1),
                  'synthetic-first-key',
                );
                await tapApiText(tester, 'Connect');
                expect(lost, isTrue);
                expect(secure.values.containsKey(marker), isFalse);
                expect(
                  secure.values['${name}_base_url'],
                  'https://new.invalid',
                );
                expect(secure.values['${name}_api_key'], 'synthetic-first-key');
                final state = connection.read() as AsyncValue<Object?>;
                expect(
                  state.error,
                  isA<DirectHomeAccessException>().having(
                    (e) => e.code,
                    'code',
                    'write_unconfirmed',
                  ),
                );
                expect(requests, 1);
                expect(find.byType(ArrConnectForm), findsOneWidget);
                expect(
                  find.byType(CupertinoTextFormFieldRow),
                  findsNWidgets(2),
                );
                expect(
                  tester
                      .widgetList<CupertinoTextFormFieldRow>(
                        find.byType(CupertinoTextFormFieldRow),
                      )
                      .map((f) => f.controller!.text),
                  everyElement(isEmpty),
                );
                expect(find.byType(LanDiscoverySection), findsNothing);
                expect(wifiQueries, 0);
                expect(
                  find.textContaining('synthetic-first-key'),
                  findsNothing,
                );
                expect(
                  find.textContaining('private-storage-sentinel'),
                  findsNothing,
                );
                final before = secure.calls.length;
                await pumpApiFrames(tester);
                expect(secure.calls.length, before);
                expect(requests, 1);
                if (recovery == 'clear') {
                  await tapApiText(tester, 'Remove saved connection');
                  expect(secure.values.containsKey(marker), isFalse);
                  expect(
                    secure.values.containsKey('${name}_base_url'),
                    isFalse,
                  );
                  expect(secure.values.containsKey('${name}_api_key'), isFalse);
                  expect(find.text('Done'), findsOneWidget);
                  expect(requests, 1);
                  expect(find.byType(LanDiscoverySection), findsNothing);
                } else {
                  await tester.enterText(
                    find.byType(CupertinoTextFormFieldRow).at(0),
                    'https://new.invalid',
                  );
                  await tester.enterText(
                    find.byType(CupertinoTextFormFieldRow).at(1),
                    'synthetic-confirmed-key',
                  );
                  await tapApiText(tester, 'Connect');
                  expect(
                    secure.values['${name}_api_key'],
                    'synthetic-confirmed-key',
                  );
                  expect(secure.values.containsKey(marker), isFalse);
                  expect(
                    (connection.read() as AsyncValue<Object?>).hasError,
                    isFalse,
                  );
                  expect(find.byType(ArrConnectForm), findsNothing);
                }
                expect(wifiQueries, 0);
                expect(tester.takeException(), isNull);
              } finally {
                await tester.pumpWidget(const SizedBox.shrink());
                connection.close();
                c.dispose();
                await pumpApiFrames(tester);
              }
            },
            () => MockClient((request) async {
              requests++;
              expect(request.url.host, 'new.invalid');
              final path = request.url.path;
              final body = path.endsWith('/queue')
                  ? '{"records":[]}'
                  : path.endsWith('/calendar') || path.endsWith('/indexer')
                  ? '[]'
                  : '{"results":[],"data":[]}';
              return http.Response(body, 200);
            }),
          );
        },
      );
    }
  }
}
