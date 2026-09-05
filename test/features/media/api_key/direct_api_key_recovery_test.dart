import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/media/arr/presentation/widgets/arr_connect_form.dart';
import 'package:larenor/features/media/jellyseerr/presentation/jellyseerr_connect_screen.dart';
import 'package:larenor/features/media/bazarr/presentation/bazarr_connect_screen.dart';
import 'package:larenor/features/media/prowlarr/presentation/prowlarr_connect_screen.dart';
import 'package:larenor/features/settings/presentation/settings_gate_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/discovery/lan_discovery_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/direct_api_key_credentials_test.dart';
import '../../../core/direct_home_routines_test.dart' show routinesHome;

Widget serviceConnectScreen(String name) => switch (name) {
  'jellyseerr' => const JellyseerrConnectScreen(),
  'bazarr' => const BazarrConnectScreen(),
  _ => const ProwlarrConnectScreen(),
};
String serviceHint(AppLocalizations l, String name) => switch (name) {
  'jellyseerr' => l.jellyseerrApiKeyHint,
  'bazarr' => l.bazarrApiKeyHint,
  _ => l.prowlarrApiKeyHint,
};
Future<void> pumpApiFrames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> tapApiText(WidgetTester tester, String label) async {
  final f = find.text(label).first;
  await tester.ensureVisible(f);
  await tester.tap(f);
  await pumpApiFrames(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ApiKeyPlatform secure;
  late FlutterSecureStoragePlatform previous;
  var wifiQueries = 0;
  setUp(() {
    secure = ApiKeyPlatform();
    secure.values['settings_pin'] = '2468';
    previous = FlutterSecureStoragePlatform.instance;
    FlutterSecureStoragePlatform.instance = MethodChannelFlutterSecureStorage();
    SharedPreferences.setMockInitialValues({});
    wifiQueries = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      secure.handle,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/network_info'),
      (_) async {
        wifiQueries++;
        return null;
      },
    );
  });
  tearDown(() {
    FlutterSecureStoragePlatform.instance = previous;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/network_info'),
      null,
    );
  });
  testWidgets(
    'shared form keeps its original Arr hint when no override is supplied',
    (tester) async {
      final (c, _) = await routinesHome('direct');
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: CupertinoApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ArrConnectForm(
              title: 'Sonarr',
              urlHint: '',
              onConnect: (_, _, _) async {},
            ),
          ),
        ),
      );
      await pumpApiFrames(tester);
      final l = AppLocalizations.of(
        tester.element(find.byType(ArrConnectForm)),
      );
      expect(find.text(l.arrApiKeyHint('Sonarr')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
      await pumpApiFrames(tester);
    },
  );
  for (final name in apiKeyServices) {
    for (final action in ['view', 'clear', 'connect']) {
      testWidgets(
        '$name pending seed has PIN settings path for explicit $action',
        (tester) async {
          var requests = 0;
          secure.values['${name}_connection_pending_v1'] = '1';
          final (c, _) = await routinesHome('direct');
          final interaction = AppInteractionController();
          addTearDown(interaction.dispose);
          tester.view.physicalSize = const Size(600, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await http.runWithClient(
            () async {
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
              await tapApiText(tester, 'Unlock');
              await tapApiText(tester, 'Integrations');
              await tapApiText(tester, 'Manage Integrations');
              await tapApiText(
                tester,
                '${name[0].toUpperCase()}${name.substring(1)}',
              );
              expect(find.byType(ArrConnectForm), findsOneWidget);
              expect(find.byType(LanDiscoverySection), findsNothing);
              expect(wifiQueries, 0);
              final fields = tester.widgetList<CupertinoTextFormFieldRow>(
                find.byType(CupertinoTextFormFieldRow),
              );
              expect(fields, hasLength(2));
              expect(
                fields.map((f) => f.controller!.text),
                everyElement(isEmpty),
              );
              final l = AppLocalizations.of(
                tester.element(find.byType(ArrConnectForm)),
              );
              expect(find.text(serviceHint(l, name)), findsOneWidget);
              expect(find.textContaining('old.invalid'), findsNothing);
              expect(find.textContaining('synthetic-old-key'), findsNothing);
              expect(secure.values['${name}_connection_pending_v1'], '1');
              if (action == 'clear') {
                await tapApiText(tester, 'Remove saved connection');
                expect(
                  secure.values.containsKey('${name}_connection_pending_v1'),
                  isFalse,
                );
                expect(secure.values.containsKey('${name}_base_url'), isFalse);
                expect(secure.values.containsKey('${name}_api_key'), isFalse);
                expect(find.text('Done'), findsOneWidget);
                expect(find.byType(LanDiscoverySection), findsNothing);
                expect(wifiQueries, 0);
                expect(requests, 0);
              } else if (action == 'connect') {
                await tester.enterText(
                  find.byType(CupertinoTextFormFieldRow).at(0),
                  'https://new.invalid',
                );
                await tester.enterText(
                  find.byType(CupertinoTextFormFieldRow).at(1),
                  'synthetic-new-key',
                );
                await tapApiText(tester, 'Connect');
                expect(
                  secure.values['${name}_base_url'],
                  'https://new.invalid',
                );
                expect(secure.values['${name}_api_key'], 'synthetic-new-key');
                expect(
                  secure.values.containsKey('${name}_connection_pending_v1'),
                  isFalse,
                );
                expect(find.byType(ArrConnectForm), findsNothing);
                expect(requests, greaterThanOrEqualTo(1));
              } else {
                expect(requests, 0);
              }
              expect(tester.takeException(), isNull);
              await tester.pumpWidget(const SizedBox.shrink());
              c.dispose();
              await pumpApiFrames(tester);
            },
            () => MockClient((request) async {
              requests++;
              expect(request.url.host, 'new.invalid');
              return http.Response(
                name == 'prowlarr' && request.url.path.endsWith('/indexer')
                    ? '[]'
                    : '{"results":[],"data":[]}',
                200,
              );
            }),
          );
        },
      );
    }
    for (final point in ['http', 'field']) {
      testWidgets(
        '$name actual wrapper retains action authority through $point await',
        (tester) async {
          secure.values['${name}_connection_pending_v1'] = '1';
          final (c, _) = await routinesHome('direct');
          final interaction = AppInteractionController();
          addTearDown(interaction.dispose);
          var requests = 0;
          final response = Completer<http.Response>();
          secure.afterEffect = (call) async {
            if (point == 'field' &&
                call.method == 'write' &&
                (call.arguments as Map)['key'] == '${name}_base_url') {
              interaction.setActive(false);
            }
          };
          await http.runWithClient(
            () async {
              await tester.pumpWidget(
                UncontrolledProviderScope(
                  container: c,
                  child: CupertinoApp(
                    localizationsDelegates:
                        AppLocalizations.localizationsDelegates,
                    supportedLocales: AppLocalizations.supportedLocales,
                    builder: (_, child) => AppInteractionScope(
                      controller: interaction,
                      child: child!,
                    ),
                    home: serviceConnectScreen(name),
                  ),
                ),
              );
              await pumpApiFrames(tester);
              await tester.enterText(
                find.byType(CupertinoTextFormFieldRow).at(0),
                'https://new.invalid',
              );
              await tester.enterText(
                find.byType(CupertinoTextFormFieldRow).at(1),
                'synthetic-new',
              );
              secure.calls.clear();
              await tapApiText(tester, 'Connect');
              expect(requests, 1);
              if (point == 'http') interaction.setActive(false);
              response.complete(http.Response('{}', 200));
              await pumpApiFrames(tester);
              expect(secure.values['${name}_api_key'], 'synthetic-old-key');
              expect(secure.values['${name}_connection_pending_v1'], '1');
              if (point == 'http') {
                expect(
                  secure.calls.where((call) => call.$1 != 'read'),
                  isEmpty,
                );
              }
              expect(wifiQueries, 0);
              expect(tester.takeException(), isNull);
              await tester.pumpWidget(const SizedBox.shrink());
              c.dispose();
              await pumpApiFrames(tester);
            },
            () => MockClient((_) {
              requests++;
              return response.future;
            }),
          );
        },
      );
    }
    testWidgets(
      '$name stale native connect cannot use a new draft after idle',
      (tester) async {
        secure.values['${name}_connection_pending_v1'] = '1';
        final (c, _) = await routinesHome('direct');
        final interaction = AppInteractionController();
        addTearDown(interaction.dispose);
        var requests = 0;
        await http.runWithClient(
          () async {
            await tester.pumpWidget(
              UncontrolledProviderScope(
                container: c,
                child: CupertinoApp(
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  builder: (_, child) => AppInteractionScope(
                    controller: interaction,
                    child: child!,
                  ),
                  home: serviceConnectScreen(name),
                ),
              ),
            );
            await pumpApiFrames(tester);
            final old = tester
                .widget<CupertinoButton>(
                  find.widgetWithText(CupertinoButton, 'Connect'),
                )
                .onPressed!;
            interaction.setActive(false);
            await pumpApiFrames(tester);
            interaction.setActive(true);
            await pumpApiFrames(tester);
            await tester.enterText(
              find.byType(CupertinoTextFormFieldRow).at(0),
              'https://new.invalid',
            );
            await tester.enterText(
              find.byType(CupertinoTextFormFieldRow).at(1),
              'synthetic-new',
            );
            secure.calls.clear();
            old();
            await pumpApiFrames(tester);
            expect(requests, 0);
            expect(secure.calls, isEmpty);
            expect(wifiQueries, 0);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
            c.dispose();
            await pumpApiFrames(tester);
          },
          () => MockClient((_) async {
            requests++;
            return http.Response('{}', 200);
          }),
        );
      },
    );
    testWidgets(
      '$name standalone Direct wrapper keeps notifier alive through explicit first connect',
      (tester) async {
        secure.values.remove('${name}_base_url');
        secure.values.remove('${name}_api_key');
        final (c, _) = await routinesHome('direct');
        var requests = 0;
        await http.runWithClient(
          () async {
            await tester.pumpWidget(
              UncontrolledProviderScope(
                container: c,
                child: CupertinoApp(
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  home: serviceConnectScreen(name),
                ),
              ),
            );
            await pumpApiFrames(tester);
            await c.pump();
            final l = AppLocalizations.of(
              tester.element(find.byType(ArrConnectForm)),
            );
            expect(find.text(serviceHint(l, name)), findsOneWidget);
            expect(wifiQueries, 1);
            await tester.enterText(
              find.byType(CupertinoTextFormFieldRow).at(0),
              'https://new.invalid',
            );
            await tester.enterText(
              find.byType(CupertinoTextFormFieldRow).at(1),
              'synthetic-new',
            );
            await tapApiText(tester, 'Connect');
            expect(requests, 1);
            expect(secure.values['${name}_api_key'], 'synthetic-new');
            expect(
              secure.values.containsKey('${name}_connection_pending_v1'),
              isFalse,
            );
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
            c.dispose();
            await pumpApiFrames(tester);
          },
          () => MockClient((request) async {
            requests++;
            expect(request.url.host, 'new.invalid');
            return http.Response('{}', 200);
          }),
        );
      },
    );
    testWidgets(
      '$name pushed standalone connect returns to its original route after successful signIn',
      (tester) async {
        secure.values['${name}_connection_pending_v1'] = '1';
        final (c, _) = await routinesHome('direct');
        final navigator = GlobalKey<NavigatorState>();
        var requests = 0;
        await http.runWithClient(
          () async {
            await tester.pumpWidget(
              UncontrolledProviderScope(
                container: c,
                child: CupertinoApp(
                  navigatorKey: navigator,
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  home: CupertinoPageScaffold(
                    child: Center(
                      child: CupertinoButton(
                        onPressed: () => navigator.currentState!.push<void>(
                          CupertinoPageRoute(
                            builder: (_) => serviceConnectScreen(name),
                          ),
                        ),
                        child: const Text('Original route'),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await pumpApiFrames(tester);
            await tapApiText(tester, 'Original route');
            expect(navigator.currentState!.canPop(), isTrue);
            expect(find.byType(ArrConnectForm), findsOneWidget);
            expect(find.text('Original route'), findsNothing);
            await tester.enterText(
              find.byType(CupertinoTextFormFieldRow).at(0),
              'https://new.invalid',
            );
            await tester.enterText(
              find.byType(CupertinoTextFormFieldRow).at(1),
              'synthetic-new',
            );
            await tapApiText(tester, 'Connect');
            expect(requests, 1);
            expect(secure.values['${name}_api_key'], 'synthetic-new');
            expect(
              secure.values.containsKey('${name}_connection_pending_v1'),
              isFalse,
            );
            expect(navigator.currentState!.canPop(), isFalse);
            expect(find.text('Original route'), findsOneWidget);
            expect(find.byType(ArrConnectForm), findsNothing);
            expect(wifiQueries, 0);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
            c.dispose();
            await pumpApiFrames(tester);
          },
          () => MockClient((request) async {
            requests++;
            expect(request.url.host, 'new.invalid');
            return http.Response('{}', 200);
          }),
        );
      },
    );
    for (final language in ['en', 'tr']) {
      testWidgets(
        '$name $language 2x real-font recovery preserves correct service hint',
        (tester) async {
          await tester.runAsync(() async {
            final font = await rootBundle.load(
              'assets/fonts/Inter-Variable.ttf',
            );
            for (final family in [
              'Inter',
              'CupertinoSystemText',
              'CupertinoSystemDisplay',
            ]) {
              await (FontLoader(family)..addFont(Future.value(font))).load();
            }
          });
          tester.view.physicalSize = const Size(600, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          secure.values['${name}_connection_pending_v1'] = '1';
          final (c, _) = await routinesHome('direct');
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: c,
              child: CupertinoApp(
                locale: Locale(language),
                theme: CupertinoThemeData(
                  brightness: language == 'tr'
                      ? Brightness.dark
                      : Brightness.light,
                ),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(2)),
                  child: child!,
                ),
                home: serviceConnectScreen(name),
              ),
            ),
          );
          await pumpApiFrames(tester);
          final l = AppLocalizations.of(
            tester.element(find.byType(ArrConnectForm)),
          );
          expect(find.text(serviceHint(l, name)), findsOneWidget);
          expect(find.text(l.arrApiKeyHint(name)), findsNothing);
          await tapApiText(tester, l.arrRemoveConnection);
          expect(find.text(l.commonDone), findsOneWidget);
          expect(wifiQueries, 0);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          c.dispose();
          await pumpApiFrames(tester);
        },
      );
    }
    testWidgets(
      '$name directly mounted Core connect consumer has no discovery, fields or storage',
      (tester) async {
        final (c, _) = await routinesHome('core');
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: c,
            child: CupertinoApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: serviceConnectScreen(name),
            ),
          ),
        );
        await pumpApiFrames(tester);
        expect(find.byType(LanDiscoverySection), findsNothing);
        expect(find.byType(CupertinoTextFormFieldRow), findsNothing);
        expect(wifiQueries, 0);
        expect(secure.calls, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
        c.dispose();
        await pumpApiFrames(tester);
      },
    );
  }
}
