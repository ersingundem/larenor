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
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/media/qbittorrent/presentation/qbittorrent_connect_screen.dart';
import 'package:larenor/features/media/qbittorrent/presentation/qbittorrent_torrents_screen.dart';
import 'package:larenor/features/media/qbittorrent/providers/qbittorrent_providers.dart';
import 'package:larenor/features/settings/presentation/settings_gate_screen.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/discovery/lan_discovery_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/direct_home_boundary_test.dart' show SecurePlatform;
import '../../../core/direct_home_routines_test.dart' show routinesHome;
import 'qbittorrent_providers_test.dart' show success;

const marker = 'qbittorrent_connection_pending_v1';
const fields = {
  'qbittorrent_base_url': 'https://old.invalid',
  'qbittorrent_username': 'old-user',
  'qbittorrent_password': 'synthetic-old-password',
};
const storageChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);
const networkChannel = MethodChannel('dev.fluttercommunity.plus/network_info');

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> tap(WidgetTester tester, String text) async {
  final matches = find.text(text);
  if (matches.evaluate().isEmpty &&
      find.byType(QbittorrentConnectScreen).evaluate().isNotEmpty) {
    await tester.scrollUntilVisible(
      matches,
      250,
      scrollable: find
          .descendant(
            of: find.byType(QbittorrentConnectScreen),
            matching: find.byType(Scrollable),
          )
          .first,
      maxScrolls: 30,
    );
  }
  final button = matches.first;
  await Scrollable.ensureVisible(tester.element(button), alignment: .4);
  await settle(tester);
  await tester.tap(button);
  await settle(tester);
}

Future<void> fill(WidgetTester tester) async {
  final rows = find.byType(CupertinoTextFormFieldRow);
  await tester.enterText(rows.at(0), 'https://new.invalid');
  await tester.enterText(rows.at(1), 'new-user');
  await tester.enterText(rows.at(2), 'synthetic-new-password');
}

Future<void> mount(
  WidgetTester tester,
  ProviderContainer c,
  AppInteractionController interaction, {
  Widget child = const QbittorrentConnectScreen(),
  ValueNotifier<bool>? visible,
  Size size = const Size(700, 1100),
  double scale = 1,
  Locale locale = const Locale('en'),
}) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: CupertinoApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, body) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: AppInteractionScope(
            controller: interaction,
            child: visible == null
                ? body!
                : ValueListenableBuilder<bool>(
                    valueListenable: visible,
                    child: body,
                    builder: (_, value, child) =>
                        TickerMode(enabled: value, child: child!),
                  ),
          ),
        ),
        home: child,
      ),
    ),
  );
  await settle(tester);
}

Future<void> finish(WidgetTester tester, ProviderContainer c) async {
  await tester.pumpWidget(const SizedBox());
  c.dispose();
  await settle(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SecurePlatform secure;
  late FlutterSecureStoragePlatform previous;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secure = SecurePlatform()
      ..values.clear()
      ..values['settings_pin'] = '2468';
    previous = FlutterSecureStoragePlatform.instance;
    FlutterSecureStoragePlatform.instance = MethodChannelFlutterSecureStorage();
    messenger.setMockMethodCallHandler(storageChannel, secure.handle);
    // The real discovery widget sees no LAN address. It cannot scan the home.
    messenger.setMockMethodCallHandler(networkChannel, (_) async => null);
  });
  tearDown(() {
    FlutterSecureStoragePlatform.instance = previous;
    messenger.setMockMethodCallHandler(storageChannel, null);
    messenger.setMockMethodCallHandler(networkChannel, null);
  });

  for (final change in ['ticker', 'route']) {
    testWidgets(
      'held connected refresh after $change cannot dispatch another read',
      (tester) async {
        secure.values.addAll(fields);
        final (c, _) = await routinesHome('direct');
        final interaction = AppInteractionController();
        final visible = ValueNotifier(true);
        addTearDown(interaction.dispose);
        addTearDown(visible.dispose);
        var requests = 0;
        await http.runWithClient(
          () async {
            await mount(
              tester,
              c,
              interaction,
              visible: visible,
              child: const QbittorrentTorrentsScreen(),
            );
            expect(requests, 4); // Cookie login, two versions, then a read.
            final old = tester
                .widget<CupertinoButton>(
                  find.byKey(const ValueKey('torrent-refresh')),
                )
                .onPressed!;
            if (change == 'ticker') {
              visible.value = false;
              await settle(tester);
              visible.value = true;
            } else {
              final navigator = Navigator.of(
                tester.element(find.byType(QbittorrentTorrentsScreen)),
              );
              unawaited(
                navigator.push(
                  CupertinoPageRoute<void>(
                    builder: (_) =>
                        const CupertinoPageScaffold(child: Text('Covered')),
                  ),
                ),
              );
              await settle(tester);
              navigator.pop();
            }
            await settle(tester);
            final before = requests;
            old();
            await settle(tester);
            expect(requests, before);
            await finish(tester, c);
          },
          () => MockClient((request) async {
            requests++;
            return success(request);
          }),
        );
      },
    );
  }

  for (final change in [
    'window',
    'background',
    'ticker',
    'route',
    'source',
    'dispose',
  ]) {
    testWidgets(
      'held standalone connect callback after $change performs no storage or HTTP',
      (tester) async {
        final (c, home) = await routinesHome('direct');
        final interaction = AppInteractionController();
        final visible = ValueNotifier(true);
        addTearDown(interaction.dispose);
        addTearDown(visible.dispose);
        var requests = 0;
        await http.runWithClient(
          () async {
            await mount(tester, c, interaction, visible: visible);
            await fill(tester);
            final old = tester
                .widget<CupertinoButton>(
                  find.widgetWithText(CupertinoButton, 'Connect'),
                )
                .onPressed!;
            if (change == 'window') {
              interaction.setActive(false);
              await settle(tester);
              interaction.setActive(true);
            }
            if (change == 'background') {
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.inactive,
              );
              await settle(tester);
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.resumed,
              );
            }
            if (change == 'ticker') {
              visible.value = false;
              await settle(tester);
              visible.value = true;
            }
            if (change == 'route') {
              final navigator = Navigator.of(
                tester.element(find.byType(QbittorrentConnectScreen)),
              );
              unawaited(
                navigator.push(
                  CupertinoPageRoute<void>(
                    builder: (_) =>
                        const CupertinoPageScaffold(child: Text('Covered')),
                  ),
                ),
              );
              await settle(tester);
              navigator.pop();
            }
            if (change == 'source') {
              await home.choose(HomeSource.verifiedCore);
              await home.choose(HomeSource.directLocal);
              home.runtimeMounted(home.runtimeIdentity);
            }
            if (change == 'dispose') await tester.pumpWidget(const SizedBox());
            await settle(tester);
            if (find.byType(CupertinoTextFormFieldRow).evaluate().length == 3) {
              await fill(tester);
            }
            secure.calls.clear();
            old();
            await settle(tester);
            expect(requests, 0);
            expect(secure.calls, isEmpty);
            expect(tester.takeException(), isNull);
            await finish(tester, c);
          },
          () => MockClient((request) async {
            requests++;
            return success(request);
          }),
        );
      },
    );
  }

  for (final action in ['view', 'clear', 'connect']) {
    testWidgets(
      'actual Settings PIN pending qBittorrent supports explicit $action with blank no-discovery form',
      (tester) async {
        secure.values.addAll(fields);
        secure.values[marker] = '1';
        final (c, _) = await routinesHome('direct');
        final interaction = AppInteractionController();
        addTearDown(interaction.dispose);
        final requests = <http.Request>[];
        await http.runWithClient(
          () async {
            await mount(
              tester,
              c,
              interaction,
              child: const SettingsGateScreen(),
            );
            expect(find.byType(QbittorrentConnectScreen), findsNothing);
            await tester.enterText(find.byType(CupertinoTextField), '2468');
            await tap(tester, 'Unlock');
            await tap(tester, 'Integrations');
            await tap(tester, 'Manage Integrations');
            await tap(tester, 'qBittorrent');
            expect(find.byType(QbittorrentConnectScreen), findsOneWidget);
            expect(find.byType(LanDiscoverySection), findsNothing);
            expect(
              tester
                  .widgetList<CupertinoTextFormFieldRow>(
                    find.byType(CupertinoTextFormFieldRow),
                  )
                  .map((f) => f.controller!.text),
              everyElement(isEmpty),
            );
            expect(requests, isEmpty);
            if (action == 'clear') {
              await tap(tester, 'Remove saved connection');
              expect(secure.values.containsKey(marker), isFalse);
              for (final key in fields.keys) {
                expect(secure.values.containsKey(key), isFalse);
              }
              expect(find.text('Done'), findsOneWidget);
              expect(find.byType(LanDiscoverySection), findsNothing);
              expect(requests, isEmpty);
            } else if (action == 'connect') {
              await fill(tester);
              await tap(tester, 'Connect');
              expect(secure.values[marker], isNull);
              expect(
                secure.values['qbittorrent_base_url'],
                'https://new.invalid',
              );
              expect(secure.values['qbittorrent_username'], 'new-user');
              expect(
                secure.values['qbittorrent_password'],
                'synthetic-new-password',
              );
              expect(requests.take(3).map((r) => r.url.path), [
                '/api/v2/auth/login',
                '/api/v2/app/version',
                '/api/v2/app/webapiVersion',
              ]);
              expect(find.byType(QbittorrentConnectScreen), findsNothing);
            }
            expect(tester.takeException(), isNull);
            await finish(tester, c);
          },
          () => MockClient((request) async {
            requests.add(request);
            expect(request.url.host, 'new.invalid');
            return success(request);
          }),
        );
      },
    );
  }

  for (final point in ['login', 'url', 'username', 'password']) {
    testWidgets(
      'window expiry during $point stops subsequent login or tuple effects',
      (tester) async {
        final (c, _) = await routinesHome('direct');
        final interaction = AppInteractionController();
        addTearDown(interaction.dispose);
        final response = Completer<http.Response>();
        final requests = <http.Request>[];
        messenger.setMockMethodCallHandler(storageChannel, (call) async {
          final result = await secure.handle(call);
          if (call.method == 'write' &&
              (call.arguments as Map)['key'] ==
                  'qbittorrent_${point == 'url' ? 'base_url' : point}') {
            interaction.setActive(false);
          }
          return result;
        });
        await http.runWithClient(
          () async {
            await mount(tester, c, interaction);
            await fill(tester);
            await tap(tester, 'Connect');
            expect(requests, hasLength(1));
            if (point == 'login') interaction.setActive(false);
            response.complete(
              http.Response(
                '',
                204,
                headers: {'set-cookie': 'SID=synthetic; Path=/'},
              ),
            );
            await settle(tester);
            final writes = secure.calls
                .where((c) => c.$1 != 'read')
                .map((c) => c.$2)
                .toList();
            if (point == 'login') {
              expect(requests, hasLength(1));
              expect(writes, isEmpty);
            } else {
              final expected = [
                marker,
                'qbittorrent_base_url',
                if (point != 'url') 'qbittorrent_username',
                if (point == 'password') 'qbittorrent_password',
              ];
              expect(writes, expected);
              expect(secure.values[marker], '1');
            }
            final connection = c.read(qbittorrentConnectionProvider);
            expect(
              connection.isLoading ||
                  connection.hasError ||
                  connection.value == null,
              isTrue,
            );
            expect(tester.takeException(), isNull);
            await finish(tester, c);
          },
          () => MockClient((request) async {
            requests.add(request);
            if (request.url.path.endsWith('/auth/login')) {
              return response.future;
            }
            return success(request);
          }),
        );
      },
    );
  }
  for (final mode in ['core', 'pending', 'error']) {
    testWidgets(
      '$mode standalone setup cannot read credentials or mount LAN discovery',
      (tester) async {
        final (c, _) = await routinesHome(mode);
        final interaction = AppInteractionController();
        addTearDown(interaction.dispose);
        var requests = 0;
        await http.runWithClient(
          () async {
            secure.calls.clear();
            await mount(tester, c, interaction);
            expect(find.byType(LanDiscoverySection), findsNothing);
            expect(find.byType(CupertinoTextFormFieldRow), findsNothing);
            expect(secure.calls, isEmpty);
            expect(requests, 0);
            await finish(tester, c);
          },
          () => MockClient((request) async {
            requests++;
            return success(request);
          }),
        );
      },
    );
  }

  for (final covered in [false, true]) {
    testWidgets(
      'standalone completion covered=$covered only pops its own still-current route',
      (tester) async {
        final (c, _) = await routinesHome('direct');
        final interaction = AppInteractionController();
        addTearDown(interaction.dispose);
        final response = Completer<http.Response>();
        var requests = 0;
        await http.runWithClient(
          () async {
            await mount(
              tester,
              c,
              interaction,
              child: Builder(
                builder: (context) => CupertinoPageScaffold(
                  child: Center(
                    child: CupertinoButton(
                      onPressed: () => Navigator.of(context).push(
                        CupertinoPageRoute<void>(
                          builder: (_) => const QbittorrentConnectScreen(),
                        ),
                      ),
                      child: const Text('Open setup'),
                    ),
                  ),
                ),
              ),
            );
            await tap(tester, 'Open setup');
            await fill(tester);
            await tap(tester, 'Connect');
            expect(requests, 1);
            if (covered) {
              final navigator = Navigator.of(
                tester.element(find.byType(QbittorrentConnectScreen)),
              );
              unawaited(
                navigator.push(
                  CupertinoPageRoute<void>(
                    builder: (_) => const CupertinoPageScaffold(
                      child: Center(child: Text('Unrelated page')),
                    ),
                  ),
                ),
              );
              await settle(tester);
            }
            response.complete(
              http.Response(
                '',
                204,
                headers: {'set-cookie': 'SID=synthetic; Path=/'},
              ),
            );
            await settle(tester);
            if (covered) {
              expect(find.text('Unrelated page'), findsOneWidget);
              expect(requests, 1);
              expect(secure.calls.where((c) => c.$1 == 'write'), isEmpty);
            } else {
              expect(find.text('Open setup'), findsOneWidget);
              expect(find.byType(QbittorrentConnectScreen), findsNothing);
              expect(requests, 3);
              expect(
                secure.values['qbittorrent_password'],
                'synthetic-new-password',
              );
            }
            expect(tester.takeException(), isNull);
            await finish(tester, c);
          },
          () => MockClient((request) async {
            requests++;
            return request.url.path.endsWith('/auth/login')
                ? response.future
                : success(request);
          }),
        );
      },
    );
  }

  testWidgets(
    'actual Settings PIN replacement retires held recovery clear and connect callbacks',
    (tester) async {
      secure.values.addAll(fields);
      secure.values[marker] = '1';
      final (c, _) = await routinesHome('direct');
      final interaction = AppInteractionController();
      addTearDown(interaction.dispose);
      var requests = 0;
      final response = Completer<http.Response>();
      await http.runWithClient(
        () async {
          await mount(
            tester,
            c,
            interaction,
            child: const SettingsGateScreen(),
          );
          await tester.enterText(find.byType(CupertinoTextField), '2468');
          await tap(tester, 'Unlock');
          await tap(tester, 'Integrations');
          await tap(tester, 'Manage Integrations');
          await tap(tester, 'qBittorrent');
          await fill(tester);
          final oldClear = tester
              .widget<CupertinoButton>(
                find.widgetWithText(CupertinoButton, 'Remove saved connection'),
              )
              .onPressed!;
          final oldConnect = tester
              .widget<CupertinoButton>(
                find.widgetWithText(CupertinoButton, 'Connect'),
              )
              .onPressed!;
          oldConnect();
          await settle(tester);
          expect(requests, 1);
          secure.values['settings_pin'] = '1357';
          c.invalidate(pinLockProvider);
          await settle(tester);
          expect(find.byType(QbittorrentConnectScreen), findsNothing);
          secure.calls.clear();
          oldClear();
          oldConnect();
          response.complete(
            http.Response(
              '',
              204,
              headers: {'set-cookie': 'SID=synthetic; Path=/'},
            ),
          );
          await settle(tester);
          expect(secure.calls, isEmpty);
          expect(requests, 1);
          expect(secure.values[marker], '1');
          expect(
            secure.values['qbittorrent_password'],
            fields['qbittorrent_password'],
          );
          expect(tester.takeException(), isNull);
          await finish(tester, c);
        },
        () => MockClient((request) async {
          requests++;
          return request.url.path.endsWith('/auth/login')
              ? response.future
              : success(request);
        }),
      );
    },
  );

  testWidgets(
    'pending clear platform failure is static, retains marker and never discovers or signs in',
    (tester) async {
      secure.values.addAll(fields);
      secure.values[marker] = '1';
      messenger.setMockMethodCallHandler(storageChannel, (call) async {
        final result = await secure.handle(call);
        if (call.method == 'delete' &&
            (call.arguments as Map)['key'] == 'qbittorrent_base_url') {
          throw PlatformException(
            code: 'synthetic',
            message: 'synthetic-private-password',
          );
        }
        return result;
      });
      final (c, _) = await routinesHome('direct');
      final interaction = AppInteractionController();
      addTearDown(interaction.dispose);
      var requests = 0;
      await http.runWithClient(
        () async {
          await mount(
            tester,
            c,
            interaction,
            child: const QbittorrentTorrentsScreen(),
          );
          await tap(tester, 'Remove saved connection');
          expect(secure.values[marker], '1');
          expect(find.text('Done'), findsNothing);
          expect(
            find.textContaining('synthetic-private-password'),
            findsNothing,
          );
          expect(find.byType(LanDiscoverySection), findsNothing);
          expect(requests, 0);
          expect(
            tester
                .widget<CupertinoButton>(
                  find.widgetWithText(
                    CupertinoButton,
                    'Remove saved connection',
                  ),
                )
                .onPressed,
            isNotNull,
          );
          await finish(tester, c);
        },
        () => MockClient((request) async {
          requests++;
          return success(request);
        }),
      );
    },
  );
  for (final layout in [
    (const Size(320, 640), const Locale('tr')),
    (const Size(1366, 1024), const Locale('en')),
  ]) {
    testWidgets(
      'pending recovery fits ${layout.$1} ${layout.$2.languageCode} with 2x text',
      (tester) async {
        secure.values.addAll(fields);
        secure.values[marker] = '1';
        final (c, _) = await routinesHome('direct');
        final interaction = AppInteractionController();
        addTearDown(interaction.dispose);
        var requests = 0;
        await http.runWithClient(
          () async {
            await mount(
              tester,
              c,
              interaction,
              child: const QbittorrentTorrentsScreen(),
              size: layout.$1,
              scale: 2,
              locale: layout.$2,
            );
            final label = layout.$2.languageCode == 'tr'
                ? 'Kayıtlı bağlantıyı kaldır'
                : 'Remove saved connection';
            await tap(tester, label);
            final list = find
                .descendant(
                  of: find.byType(QbittorrentConnectScreen),
                  matching: find.byType(Scrollable),
                )
                .first;
            tester.state<ScrollableState>(list).position.jumpTo(0);
            await settle(tester);
            expect(
              find.text(layout.$2.languageCode == 'tr' ? 'Bitti' : 'Done'),
              findsOneWidget,
            );
            expect(secure.values[marker], isNull);
            expect(requests, 0);
            expect(tester.takeException(), isNull);
            await finish(tester, c);
          },
          () => MockClient((request) async {
            requests++;
            return success(request);
          }),
        );
      },
    );
  }

  testWidgets(
    'pending rejected login keeps the no-discovery form and requires explicit retry',
    (tester) async {
      secure.values.addAll(fields);
      secure.values[marker] = '1';
      final (c, _) = await routinesHome('direct');
      final interaction = AppInteractionController();
      addTearDown(interaction.dispose);
      var logins = 0, requests = 0;
      await http.runWithClient(
        () async {
          await mount(
            tester,
            c,
            interaction,
            child: const QbittorrentTorrentsScreen(),
          );
          await fill(tester);
          await tap(tester, 'Connect');
          expect(logins, 1);
          expect(requests, 1);
          expect(secure.values[marker], '1');
          expect(find.byType(QbittorrentConnectScreen), findsOneWidget);
          expect(find.byType(LanDiscoverySection), findsNothing);
          expect(
            find.textContaining('synthetic-private-upstream'),
            findsNothing,
          );
          await settle(tester);
          expect(logins, 1);
          await tap(tester, 'Connect');
          expect(secure.values[marker], isNull);
          expect(
            logins,
            3,
          ); // Explicit verifier, then the new normal reader session.
          expect(find.byType(QbittorrentConnectScreen), findsNothing);
          await finish(tester, c);
        },
        () => MockClient((request) async {
          requests++;
          if (request.url.path.endsWith('/auth/login') && ++logins == 1) {
            return http.Response('synthetic-private-upstream', 200);
          }
          return success(request);
        }),
      );
    },
  );
  for (final change in ['background', 'ticker', 'source', 'dispose']) {
    testWidgets(
      '$change during owned login cancels remaining version reads and credential writes',
      (tester) async {
        final (c, home) = await routinesHome('direct');
        final interaction = AppInteractionController();
        final visible = ValueNotifier(true);
        addTearDown(interaction.dispose);
        addTearDown(visible.dispose);
        final response = Completer<http.Response>();
        var requests = 0;
        await http.runWithClient(
          () async {
            await mount(tester, c, interaction, visible: visible);
            await fill(tester);
            await tap(tester, 'Connect');
            expect(requests, 1);
            if (change == 'background') {
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.inactive,
              );
            }
            if (change == 'ticker') visible.value = false;
            if (change == 'source') await home.choose(HomeSource.verifiedCore);
            if (change == 'dispose') await tester.pumpWidget(const SizedBox());
            await settle(tester);
            response.complete(
              http.Response(
                '',
                204,
                headers: {'set-cookie': 'SID=synthetic; Path=/'},
              ),
            );
            await settle(tester);
            expect(requests, 1);
            expect(secure.calls.where((call) => call.$1 == 'write'), isEmpty);
            expect(tester.takeException(), isNull);
            await finish(tester, c);
          },
          () => MockClient((request) async {
            requests++;
            return request.url.path.endsWith('/auth/login')
                ? response.future
                : success(request);
          }),
        );
      },
    );
  }
}
