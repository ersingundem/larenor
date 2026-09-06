import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState, ViewFocusDirection;

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
import 'package:larenor/features/settings/presentation/idle_gate.dart';
import 'package:larenor/features/keenetic/presentation/keenetic_devices_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
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
    'reload',
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
          } else if (change == 'reload') {
            c.invalidate(keeneticConnectionProvider);
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

  testWidgets('connected root explicit sign-out clears the complete tuple', (
    tester,
  ) async {
    secure.values.addAll(keeneticRecord);
    final (c, _) = await routinesHome('direct');
    final interaction = AppInteractionController();
    addTearDown(interaction.dispose);
    await http.runWithClient(() async {
      await mount(tester, c, interaction, child: const KeeneticHomeScreen());
      await tester.tap(find.byKey(const ValueKey('service-account-action')));
      await settle(tester);
      expect(
        secure.values.keys.where((k) => k.startsWith('keenetic_')),
        isEmpty,
      );
      expect(await c.read(keeneticConnectionProvider.future), isNull);
      expect(tester.takeException(), isNull);
      await finish(tester, c);
    }, () => MockClient((r) async => keeneticReply(r)));
  });

  for (final field in ['http', ...keeneticRecord.keys]) {
    testWidgets(
      'verification loses window during $field and cannot finish tuple',
      (tester) async {
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
        await http.runWithClient(
          () async {
            await mount(
              tester,
              c,
              interaction,
              child: const KeeneticHomeScreen(),
            );
            await fill(tester);
            await tap(tester, 'Connect');
            expect(reached, isTrue);
            expect(secure.values[marker], '1');
            expect(c.read(keeneticConnectionProvider).hasError, isTrue);
            expect(
              tester
                  .widgetList<CupertinoTextFormFieldRow>(
                    find.byType(CupertinoTextFormFieldRow),
                  )
                  .map((f) => f.controller!.text),
              everyElement(isEmpty),
            );
            final writes = secure.calls
                .where((x) => x.$1 == 'write')
                .map((x) => x.$2)
                .toList();
            if (field == 'http') {
              expect(writes, isEmpty);
            } else {
              final index = keeneticRecord.keys.toList().indexOf(field);
              expect(writes, [marker, ...keeneticRecord.keys.take(index + 1)]);
            }
            interaction.setActive(true);
            await settle(tester);
            expect(c.read(keeneticConnectionProvider).hasError, isTrue);
            expect(tester.takeException(), isNull);
            await finish(tester, c);
          },
          () => MockClient((r) async {
            if (field == 'http' && r.url.path.endsWith('/version')) {
              reached = true;
              interaction.setActive(false);
            }
            return keeneticReply(r);
          }),
        );
      },
    );
  }

  for (final action in ['refresh', 'navigate', 'signOut']) {
    testWidgets(
      'connected root old $action callback expires but fresh action works',
      (tester) async {
        secure.values.addAll(keeneticRecord);
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
            VoidCallback callback() {
              if (action == 'navigate') {
                return tester
                    .widgetList<CupertinoListTile>(
                      find.byType(CupertinoListTile),
                    )
                    .first
                    .onTap!;
              }
              if (action == 'signOut')
                return tester
                    .widget<CupertinoButton>(
                      find.byKey(const ValueKey('service-account-action')),
                    )
                    .onPressed!;
              return tester
                  .widgetList<CupertinoButton>(find.byType(CupertinoButton))
                  .firstWhere(
                    (b) =>
                        b.child is Icon &&
                        (b.child as Icon).icon == CupertinoIcons.refresh,
                  )
                  .onPressed!;
            }

            final old = callback();
            interaction.setActive(false);
            await settle(tester);
            interaction.setActive(true);
            await settle(tester);
            final before = requests;
            secure.calls.clear();
            old();
            await settle(tester);
            expect(requests, before);
            expect(secure.calls.where((c) => c.$1 != 'read'), isEmpty);
            expect(find.byType(KeeneticDevicesScreen), findsNothing);
            callback()();
            await settle(tester);
            if (action == 'refresh') expect(requests, greaterThan(before));
            if (action == 'navigate')
              expect(find.byType(KeeneticDevicesScreen), findsOneWidget);
            if (action == 'signOut')
              expect(
                secure.values.keys.where((k) => k.startsWith('keenetic_')),
                isEmpty,
              );
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

  testWidgets(
    'sign-out window loss after first deletion leaves quarantine for explicit recovery',
    (tester) async {
      secure.values.addAll(keeneticRecord);
      final (c, _) = await routinesHome('direct');
      final interaction = AppInteractionController();
      addTearDown(interaction.dispose);
      messenger.setMockMethodCallHandler(storageChannel, (call) async {
        final result = await secure.handle(call);
        if (call.method == 'delete' &&
            (call.arguments as Map)['key'] == 'keenetic_base_url')
          interaction.setActive(false);
        return result;
      });
      await http.runWithClient(() async {
        await mount(tester, c, interaction, child: const KeeneticHomeScreen());
        await tester.tap(find.byKey(const ValueKey('service-account-action')));
        await settle(tester);
        expect(secure.values[marker], '1');
        expect(secure.values['keenetic_base_url'], isNull);
        expect(
          secure.values['keenetic_username'],
          keeneticRecord['keenetic_username'],
        );
        expect(c.read(keeneticConnectionProvider).hasError, isTrue);
        interaction.setActive(true);
        await settle(tester);
        expect(
          tester
              .widgetList<CupertinoTextFormFieldRow>(
                find.byType(CupertinoTextFormFieldRow),
              )
              .map((f) => f.controller!.text),
          everyElement(isEmpty),
        );
        expect(gatewayReads, 0);
        expect(tester.takeException(), isNull);
        await finish(tester, c);
      }, () => MockClient((r) async => keeneticReply(r)));
    },
  );

  for (final interrupted in [false, true]) {
    testWidgets(
      'late gateway prefill preserves ${interrupted ? 'retired' : 'edited'} draft',
      (tester) async {
        final gateway = Completer<String?>();
        messenger.setMockMethodCallHandler(
          networkChannel,
          (_) => gateway.future,
        );
        final (c, _) = await routinesHome('direct');
        final interaction = AppInteractionController();
        addTearDown(interaction.dispose);
        await mount(
          tester,
          c,
          interaction,
          child: const KeeneticConnectScreen(),
        );
        if (interrupted) {
          interaction.setActive(false);
          await settle(tester);
          interaction.setActive(true);
        } else {
          await fill(tester);
        }
        gateway.complete(
          '192.0.2.1',
        ); // Documentation-only address; native call mocked.
        await settle(tester);
        final url = tester
            .widget<CupertinoTextFormFieldRow>(
              find.byType(CupertinoTextFormFieldRow).first,
            )
            .controller!
            .text;
        expect(url, interrupted ? isEmpty : 'https://new.invalid');
        expect(tester.takeException(), isNull);
        await finish(tester, c);
      },
    );
  }

  testWidgets(
    'actual IdleGate native focus clears setup and rejects its old callback',
    (tester) async {
      secure.values.addAll({...keeneticRecord, marker: '1'});
      final (c, _) = await routinesHome('direct');
      final outer = AppInteractionController();
      addTearDown(outer.dispose);
      var requests = 0;
      await http.runWithClient(
        () async {
          await mount(
            tester,
            c,
            outer,
            child: const IdleGate(child: KeeneticHomeScreen()),
          );
          await fill(tester);
          final old = tester
              .widget<CupertinoButton>(
                find.widgetWithText(CupertinoButton, 'Connect'),
              )
              .onPressed!;
          void focus(ViewFocusState state, {int? id}) =>
              tester.binding.handleViewFocusChanged(
                ViewFocusEvent(
                  viewId: id ?? tester.view.viewId,
                  state: state,
                  direction: ViewFocusDirection.undefined,
                ),
              );
          focus(ViewFocusState.unfocused, id: tester.view.viewId + 1);
          await settle(tester);
          expect(
            tester
                .widget<CupertinoTextFormFieldRow>(
                  find.byType(CupertinoTextFormFieldRow).first,
                )
                .controller!
                .text,
            'https://new.invalid',
          );
          focus(ViewFocusState.unfocused);
          await settle(tester);
          focus(ViewFocusState.focused);
          await settle(tester);
          expect(
            tester
                .widgetList<CupertinoTextFormFieldRow>(
                  find.byType(CupertinoTextFormFieldRow),
                )
                .map((f) => f.controller!.text),
            everyElement(isEmpty),
          );
          old();
          await settle(tester);
          expect(requests, 0);
          expect(secure.values[marker], '1');
          await fill(tester);
          await tap(tester, 'Connect');
          expect(secure.values.containsKey(marker), isFalse);
          expect(requests, greaterThanOrEqualTo(2));
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

  for (final locale in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets(
        '$locale ${width.toInt()} 2x real-font recovery is scrollable and keyboard-clearable',
        (tester) async {
          await tester.runAsync(() async {
            final data = await rootBundle.load(
              'assets/fonts/Inter-Variable.ttf',
            );
            for (final family in [
              'Inter',
              'CupertinoSystemText',
              'CupertinoSystemDisplay',
            ]) {
              await (FontLoader(family)..addFont(Future.value(data))).load();
            }
          });
          secure.values.addAll({...keeneticRecord, marker: '1'});
          final (c, _) = await routinesHome('direct');
          final interaction = AppInteractionController();
          addTearDown(interaction.dispose);
          final semantics = tester.ensureSemantics();

          await mount(
            tester,
            c,
            interaction,
            size: Size(width, 650),
            scale: 2,
            locale: Locale(locale),
            child: const KeeneticHomeScreen(),
          );
          final l10n = AppLocalizations.of(
            tester.element(find.byType(KeeneticConnectScreen)),
          );
          final clear = find.widgetWithText(
            CupertinoButton,
            l10n.keeneticRemoveConnection,
          );
          await tester.scrollUntilVisible(
            clear,
            150,
            scrollable: find.byType(Scrollable).first,
            maxScrolls: 12,
          );
          await settle(tester);
          expect(tester.getSize(clear).height, greaterThanOrEqualTo(48));
          expect(find.text(l10n.keeneticRemoveConnection), findsOneWidget);
          final buttonElement = tester.element(clear);
          bool focused() {
            var found = false;
            FocusManager.instance.primaryFocus?.context?.visitAncestorElements((
              element,
            ) {
              if (identical(element, buttonElement)) found = true;
              return !found;
            });
            return found;
          }

          for (var i = 0; i < 12 && !focused(); i++) {
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await settle(tester);
          }
          expect(focused(), isTrue);
          await tester.sendKeyEvent(LogicalKeyboardKey.space);
          await settle(tester);
          expect(
            secure.values.keys.where((k) => k.startsWith('keenetic_')),
            isEmpty,
          );
          await tester.scrollUntilVisible(
            find.text(l10n.commonDone),
            -150,
            scrollable: find.byType(Scrollable).first,
            maxScrolls: 12,
          );
          expect(find.text(l10n.commonDone), findsOneWidget);
          expect(gatewayReads, 0);
          expect(tester.takeException(), isNull);
          semantics.dispose();
          await finish(tester, c);
        },
      );
    }
  }

  testWidgets(
    'same GlobalKey form moved from retained Direct container to Core loses draft and callbacks',
    (tester) async {
      final (direct, _) = await routinesHome('direct');
      final (core, _) = await routinesHome('core');
      final interaction = AppInteractionController();
      addTearDown(interaction.dispose);
      final key = GlobalKey();
      final form = KeeneticConnectScreen(key: key);
      var requests = 0;
      await http.runWithClient(
        () async {
          await mount(tester, direct, interaction, child: form);
          await fill(tester);
          final old = tester
              .widget<CupertinoButton>(
                find.widgetWithText(CupertinoButton, 'Connect'),
              )
              .onPressed!;
          final state = key.currentState;
          final lease = direct.listen(keeneticConnectionProvider, (_, _) {});
          addTearDown(lease.close);
          secure.calls.clear();
          await mount(tester, core, interaction, child: form);
          expect(key.currentState, same(state));
          expect(find.byType(CupertinoTextFormFieldRow), findsNothing);
          expect(find.text('synthetic-new-password'), findsNothing);
          old();
          await settle(tester);
          expect(requests, 0);
          expect(secure.calls, isEmpty);
          expect(tester.takeException(), isNull);
          await finish(tester, core);
          direct.dispose();
        },
        () => MockClient((r) async {
          requests++;
          return keeneticReply(r);
        }),
      );
    },
  );

  testWidgets(
    'provider reload retires pending gateway response and keyboard submit uses current form',
    (tester) async {
      final gateway = Completer<String?>();
      messenger.setMockMethodCallHandler(networkChannel, (_) => gateway.future);
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
            child: const KeeneticConnectScreen(),
          );
          c.invalidate(keeneticConnectionProvider);
          await settle(tester);
          gateway.complete('192.0.2.1');
          await settle(tester);
          final fields = tester
              .widgetList<CupertinoTextFormFieldRow>(
                find.byType(CupertinoTextFormFieldRow),
              )
              .toList();
          expect(fields.map((f) => f.controller!.text), everyElement(isEmpty));
          final inputs = tester
              .widgetList<CupertinoTextField>(find.byType(CupertinoTextField))
              .toList();
          expect(inputs.every((f) => f.autocorrect == false), isTrue);
          expect(inputs.last.enableSuggestions, isFalse);
          await fill(tester);
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await settle(tester);
          expect(requests, 2);
          expect(secure.values['keenetic_base_url'], 'https://new.invalid');
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
