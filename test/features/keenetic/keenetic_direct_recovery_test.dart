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
import 'package:larenor/core/direct_credential_record.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/keenetic/presentation/keenetic_connect_screen.dart';
import 'package:larenor/features/keenetic/presentation/keenetic_home_screen.dart';
import 'package:larenor/features/settings/presentation/settings_gate_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:larenor/features/keenetic/providers/keenetic_providers.dart';

import '../../core/direct_home_boundary_test.dart' show SecurePlatform;
import '../../core/direct_home_routines_test.dart' show routinesHome;
import '../../core/direct_keenetic_boundary_test.dart'
    show keeneticRecord, keeneticReply;
import '../media/qbittorrent/qbittorrent_direct_recovery_test.dart'
    show mount, settle, finish, fill;

const storageChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);
const networkChannel = MethodChannel('dev.fluttercommunity.plus/network_info');
final marker = DirectCredentialService.keenetic.pendingMutationKey;

Future<void> tap(WidgetTester tester, String label) async {
  final finder = find.text(label);
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      200,
      scrollable: find
          .descendant(
            of: find.byType(KeeneticConnectScreen),
            matching: find.byType(Scrollable),
          )
          .first,
      maxScrolls: 20,
    );
  }
  await Scrollable.ensureVisible(tester.element(finder.first), alignment: .4);
  await settle(tester);
  await tester.tap(finder.first);
  await settle(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SecurePlatform secure;
  late FlutterSecureStoragePlatform previous;
  var gatewayReads = 0;
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
    gatewayReads = 0;
    messenger.setMockMethodCallHandler(networkChannel, (_) async {
      gatewayReads++;
      return null;
    });
  });
  tearDown(() {
    FlutterSecureStoragePlatform.instance = previous;
    messenger.setMockMethodCallHandler(storageChannel, null);
    messenger.setMockMethodCallHandler(networkChannel, null);
  });

  for (final invalid in [false, true]) {
    testWidgets(
      'root ${invalid ? 'malformed' : 'pending'} record opens blank recovery with no gateway or HTTP',
      (tester) async {
        secure.values.addAll(keeneticRecord);
        if (invalid) {
          secure.values.remove('keenetic_username');
        } else {
          secure.values[marker] = '1';
        }
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
              child: const KeeneticHomeScreen(),
            );
            final fields = tester.widgetList<CupertinoTextFormFieldRow>(
              find.byType(CupertinoTextFormFieldRow),
            );
            expect(fields, hasLength(3));
            expect(
              fields.map((f) => f.controller!.text),
              everyElement(isEmpty),
            );
            expect(find.textContaining('synthetic-password'), findsNothing);
            expect(gatewayReads, 0);
            expect(requests, 0);
            expect(tester.takeException(), isNull);
            await finish(tester, c);
          },
          () => MockClient((r) async {
            requests++;
            return keeneticReply(r);
          }),
        );
      },
    );
  }

  for (final action in ['view', 'clear', 'connect']) {
    testWidgets('PIN settings pending recovery supports explicit $action', (
      tester,
    ) async {
      secure.values.addAll({...keeneticRecord, marker: '1'});
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
            child: const SettingsGateScreen(),
            size: const Size(600, 1000),
          );
          expect(find.byType(KeeneticConnectScreen), findsNothing);
          expect(
            secure.calls.where((x) => x.$2?.startsWith('keenetic_') ?? false),
            isEmpty,
          );
          await tester.enterText(find.byType(CupertinoTextField), '2468');
          await tap(tester, 'Unlock');
          await tap(tester, 'Integrations');
          await tap(tester, 'Manage Integrations');
          await tap(tester, 'Keenetic');
          expect(find.byType(KeeneticConnectScreen), findsOneWidget);
          expect(
            tester
                .widgetList<CupertinoTextFormFieldRow>(
                  find.byType(CupertinoTextFormFieldRow),
                )
                .map((f) => f.controller!.text),
            everyElement(isEmpty),
          );
          expect(gatewayReads, 0);
          expect(requests, 0);
          if (action == 'clear') {
            await tap(tester, 'Remove saved connection');
            expect(
              secure.values.keys.where((k) => k.startsWith('keenetic_')),
              isEmpty,
            );
            expect(find.text('Done'), findsOneWidget);
            expect(gatewayReads, 0);
            expect(requests, 0);
          } else if (action == 'connect') {
            await fill(tester);
            await tap(tester, 'Connect');
            expect(secure.values.containsKey(marker), isFalse);
            expect(secure.values['keenetic_base_url'], 'https://new.invalid');
            expect(secure.values['keenetic_username'], 'new-user');
            expect(
              secure.values['keenetic_password'],
              'synthetic-new-password',
            );
            expect(requests, greaterThanOrEqualTo(2));
          }
          expect(tester.takeException(), isNull);
          await finish(tester, c);
        },
        () => MockClient((r) async {
          requests++;
          return keeneticReply(r);
        }),
      );
    });
  }

  for (final change in [
    'window',
    'background',
    'ticker',
    'route',
    'source',
    'dispose',
  ]) {
    testWidgets('held setup callback after $change cannot request or save', (
      tester,
    ) async {
      final (c, home) = await routinesHome('direct');
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
            child: const KeeneticConnectScreen(),
            visible: visible,
          );
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
          } else if (change == 'background') {
            for (final state in [
              AppLifecycleState.inactive,
              AppLifecycleState.hidden,
              AppLifecycleState.paused,
            ]) {
              tester.binding.handleAppLifecycleStateChanged(state);
            }
            await settle(tester);
            for (final state in [
              AppLifecycleState.hidden,
              AppLifecycleState.inactive,
              AppLifecycleState.resumed,
            ]) {
              tester.binding.handleAppLifecycleStateChanged(state);
            }
          } else if (change == 'ticker') {
            visible.value = false;
            await settle(tester);
            visible.value = true;
          } else if (change == 'route') {
            final navigator = Navigator.of(
              tester.element(find.byType(KeeneticConnectScreen)),
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
          } else if (change == 'source') {
            await home.choose(HomeSource.verifiedCore);
            await home.choose(HomeSource.directLocal);
            home.runtimeMounted(home.runtimeIdentity);
          } else {
            await tester.pumpWidget(const SizedBox());
          }
          await settle(tester);
          secure.calls.clear();
          old();
          await settle(tester);
          expect(requests, 0);
          expect(secure.calls.where((x) => x.$1 != 'read'), isEmpty);
          expect(tester.takeException(), isNull);
          await finish(tester, c);
        },
        () => MockClient((r) async {
          requests++;
          return keeneticReply(r);
        }),
      );
    });
  }

  testWidgets('connected root explicit sign-out clears the complete tuple', (tester) async {
    secure.values.addAll(keeneticRecord);
    final (c, _) = await routinesHome('direct');
    final interaction = AppInteractionController();
    addTearDown(interaction.dispose);
    await http.runWithClient(() async {
      await mount(tester, c, interaction, child: const KeeneticHomeScreen());
      await tester.tap(find.byKey(const ValueKey('service-account-action')));
      await settle(tester);
      expect(secure.values.keys.where((k) => k.startsWith('keenetic_')), isEmpty);
      expect(await c.read(keeneticConnectionProvider.future), isNull);
      expect(tester.takeException(), isNull);
      await finish(tester, c);
    }, () => MockClient((r) async => keeneticReply(r)));
  });

  for (final field in ['http', ...keeneticRecord.keys]) {
    testWidgets('verification loses window during $field and cannot finish tuple', (tester) async {
      secure.values.addAll({...keeneticRecord, marker: '1'});
      final (c, _) = await routinesHome('direct');
      final interaction = AppInteractionController();
      addTearDown(interaction.dispose);
      var reached = false;
      messenger.setMockMethodCallHandler(storageChannel, (call) async {
        final result = await secure.handle(call);
        final args = call.arguments as Map;
        if (call.method == 'write' && args['key'] == field) {
          reached = true;
          interaction.setActive(false);
        }
        return result;
      });
      await http.runWithClient(() async {
        await mount(tester, c, interaction, child: const KeeneticHomeScreen());
        await fill(tester);
        await tap(tester, 'Connect');
        expect(reached, isTrue);
        expect(secure.values[marker], '1');
        expect(c.read(keeneticConnectionProvider).hasError, isTrue);
        expect(tester.widgetList<CupertinoTextFormFieldRow>(find.byType(CupertinoTextFormFieldRow))
            .map((f) => f.controller!.text), everyElement(isEmpty));
        final writes = secure.calls.where((x) => x.$1 == 'write').map((x) => x.$2).toList();
        if (field == 'http') { expect(writes, isEmpty); }
        else {
          final index = keeneticRecord.keys.toList().indexOf(field);
          expect(writes, [marker, ...keeneticRecord.keys.take(index + 1)]);
        }
        interaction.setActive(true);
        await settle(tester);
        expect(c.read(keeneticConnectionProvider).hasError, isTrue);
        expect(tester.takeException(), isNull);
        await finish(tester, c);
      }, () => MockClient((r) async {
        if (field == 'http' && r.url.path.endsWith('/version')) {
          reached = true;
          interaction.setActive(false);
        }
        return keeneticReply(r);
      }));
    });
  }

}
