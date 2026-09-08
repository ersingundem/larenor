import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/server/admin/presentation/server_admin_screen.dart';
import 'package:larenor/features/server/presentation/server_connection_screen.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/features/settings/presentation/settings_gate_screen.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server_admin_test_support.dart';

/// Observe the real default traversal without changing its order or targets.
/// This also distinguishes one from two moves in reset's one-field closed loop.
class _TraversalTrace extends ReadingOrderTraversalPolicy {
  final nextFrom = <FocusNode>[];
  final _activeCalls = <FocusNode>[];

  @override
  bool next(FocusNode currentNode) {
    // One traversal can recursively delegate across nested Navigator scopes.
    // Count input requests, not those internal parent-scope hops.
    if (_activeCalls.isEmpty) {
      nextFrom.add(currentNode);
    }
    _activeCalls.add(currentNode);
    try {
      return super.next(currentNode);
    } finally {
      _activeCalls.removeLast();
    }
  }
}

final _cases = [
  (language: 'en', width: 600.0, scale: 1.0),
  (language: 'tr', width: 600.0, scale: 2.0),
  (language: 'en', width: 1280.0, scale: 2.0),
  (language: 'tr', width: 1280.0, scale: 1.0),
];

class _Harness {
  final fixture = AdminFixture();
  final trace = _TraversalTrace();
  final interaction = AppInteractionController();
  final navigation = GlobalKey<NavigatorState>();

  Future<void> mount(
    WidgetTester tester, {
    required bool signedIn,
    String language = 'en',
    double width = 600,
    double scale = 1,
  }) async {
    if (!signedIn) {
      fixture.store.value = null;
    }
    await tester.runAsync(fixture.account.initialize);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'settings_pin': '1234'});
    tester.view.physicalSize = Size(width, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.account.dispose();
      interaction.dispose();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(fixture.account),
        ],
        child: CupertinoApp(
          navigatorKey: navigation,
          locale: Locale(language),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: AppInteractionScope(
              controller: interaction,
              child: FocusTraversalGroup(policy: trace, child: child!),
            ),
          ),
          home: const SettingsGateScreen(
            initialDestination: SettingsGateDestination.serverAccount,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ServerConnectionScreen), findsNothing);
    expect(fixture.adminCalls, isEmpty);
    await tester.enterText(find.byType(CupertinoTextField), '1234');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.byType(ServerConnectionScreen), findsOneWidget);
    if (signedIn) {
      await _tap(tester, 'server-admin');
      expect(find.byType(ServerAdminScreen), findsOneWidget);
      expect(fixture.adminCalls, isNotEmpty);
      expect(fixture.adminCalls.every((call) => call.method == 'GET'), isTrue);
    }
    trace.nextFrom.clear();
  }
}

Finder _field(String key) => find.byKey(ValueKey(key));

EditableText _editable(WidgetTester tester, String key) =>
    tester.widget<EditableText>(
      find.descendant(of: _field(key), matching: find.byType(EditableText)),
    );

Future<void> _tap(WidgetTester tester, String key) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
  final target = _field(key);
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      target,
      250,
      scrollable: find
          .descendant(
            of: _field('admin-list'),
            matching: find.byType(Scrollable),
          )
          .first,
    );
  }
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  expect(target.hitTestable(), findsOneWidget);
  await tester.tap(target.hitTestable());
  await tester.pumpAndSettle();
}

Future<FocusNode?> _nextUsingTab(WidgetTester tester, String key) async {
  _editable(tester, key).focusNode.requestFocus();
  await tester.pumpAndSettle();
  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  await tester.pumpAndSettle();
  return FocusManager.instance.primaryFocus;
}

int _inputClient(WidgetTester tester) =>
    (tester.testTextInput.log
                .lastWhere((call) => call.method == 'TextInput.setClient')
                .arguments
            as List<dynamic>)[0]
        as int;

/// Deliver to the captured native client, never the new PIN/cover's client.
/// A framework channel error remains a test failure.
Future<void> _lateNext(WidgetTester tester, int client) async {
  final reply = await tester.binding.defaultBinaryMessenger
      .handlePlatformMessage(
        SystemChannels.textInput.name,
        SystemChannels.textInput.codec.encodeMethodCall(
          MethodCall('TextInputClient.performAction', [
            client,
            TextInputAction.next.toString(),
          ]),
        ),
        null,
      );
  SystemChannels.textInput.codec.decodeEnvelope(reply!);
}

void main() {
  for (final item in _cases) {
    final description = '${item.language} ${item.width} ${item.scale}x';
    testWidgets('login IME takes one native focus step $description', (
      tester,
    ) async {
      final h = (await tester.runAsync(() async => _Harness()))!;
      await h.mount(
        tester,
        signedIn: false,
        language: item.language,
        width: item.width,
        scale: item.scale,
      );
      final fields = [
        ('server-url', 'https://fixture.invalid/prefix'),
        ('server-username', 'fixture'),
        ('server-password', adminPassword),
        ('server-device-name', 'Tablet'),
      ];
      for (var index = 0; index < fields.length - 1; index++) {
        final (key, value) = fields[index];
        await tester.enterText(_field(key), value);
        h.trace.nextFrom.clear();
        await tester.testTextInput.receiveAction(TextInputAction.next);
        await tester.pumpAndSettle();
        expect(
          _editable(tester, fields[index + 1].$1).focusNode.hasPrimaryFocus,
          isTrue,
          reason: '$key must advance to ${fields[index + 1].$1}',
        );
        expect(h.trace.nextFrom, hasLength(1));
        expect(_fixtureRequests(h), 0);
        expect(h.fixture.store.value, isNull);
      }
      expect(_editable(tester, 'server-password').obscureText, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('admin create IME matches native role focus $description', (
      tester,
    ) async {
      final h = (await tester.runAsync(() async => _Harness()))!;
      await h.mount(
        tester,
        signedIn: true,
        language: item.language,
        width: item.width,
        scale: item.scale,
      );
      await _tap(tester, 'admin-create');
      final requestsBefore = _fixtureRequests(h);
      await tester.enterText(_field('admin-username'), 'second_member');
      final nativeTarget = await _nextUsingTab(tester, 'admin-username');
      final roleText = find.descendant(
        of: _field('admin-role-admin'),
        matching: find.byType(Text),
      );
      expect(nativeTarget, same(Focus.of(tester.element(roleText))));
      await tester.enterText(_field('admin-username'), 'second_member');
      h.trace.nextFrom.clear();
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus, same(nativeTarget));
      expect(h.trace.nextFrom, hasLength(1));
      expect(_fixtureRequests(h), requestsBefore);
      expect(h.fixture.mutations, isEmpty);
      expect(
        _editable(tester, 'admin-username').controller.text,
        'second_member',
      );
      expect(find.byKey(const ValueKey('admin-submit-user')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'admin reset IME traverses its single field once $description',
      (tester) async {
        final h = (await tester.runAsync(() async => _Harness()))!;
        await h.mount(
          tester,
          signedIn: true,
          language: item.language,
          width: item.width,
          scale: item.scale,
        );
        await _tap(tester, 'admin-reset-$memberId');
        final requestsBefore = _fixtureRequests(h);
        const key = 'admin-temporary-password';
        expect(find.byType(CupertinoTextField), findsOneWidget);
        await tester.enterText(_field(key), adminPassword);
        final nativeTarget = await _nextUsingTab(tester, key);
        await tester.enterText(_field(key), adminPassword);
        final origin = _editable(tester, key).focusNode;
        h.trace.nextFrom.clear();
        await tester.testTextInput.receiveAction(TextInputAction.next);
        await tester.pumpAndSettle();
        expect(h.trace.nextFrom, [same(origin)]);
        expect(FocusManager.instance.primaryFocus, same(nativeTarget));
        expect(_editable(tester, key).controller.text, adminPassword);
        expect(_editable(tester, key).obscureText, isTrue);
        expect(_fixtureRequests(h), requestsBefore);
        expect(h.fixture.mutations, isEmpty);
        expect(find.byType(CupertinoAlertDialog), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final form in ['login', 'create', 'reset']) {
    for (final retirement in ['covered', 'idle', 'pin', 'account']) {
      testWidgets(
        '$form late IME and held submit after $retirement have no effect',
        (tester) async {
          final h = (await tester.runAsync(() async => _Harness()))!;
          await h.mount(
            tester,
            signedIn: form != 'login',
            language: form == 'reset' ? 'en' : 'tr',
            width: form == 'reset' ? 1280 : 600,
            scale: form == 'reset' ? 1 : 2,
          );
          final VoidCallback oldSubmit;
          if (form == 'login') {
            await tester.enterText(
              _field('server-url'),
              'https://fixture.invalid/prefix',
            );
            await tester.enterText(_field('server-username'), 'fixture');
            await tester.enterText(_field('server-device-name'), 'Tablet');
            await tester.enterText(_field('server-password'), adminPassword);
            oldSubmit = tester
                .widget<CupertinoButton>(_field('server-sign-in'))
                .onPressed!;
          } else {
            await _tap(
              tester,
              form == 'create' ? 'admin-create' : 'admin-reset-$memberId',
            );
            if (form == 'create') {
              await tester.enterText(_field('admin-username'), 'second_member');
            }
            await tester.enterText(
              _field('admin-temporary-password'),
              adminPassword,
            );
            oldSubmit = tester
                .widget<CupertinoDialogAction>(_field('admin-submit-user'))
                .onPressed!;
          }
          final oldClient = _inputClient(tester);
          expect(oldClient, greaterThan(0));
          final container = ProviderScope.containerOf(
            tester.element(find.byType(SettingsGateScreen)),
          );
          switch (retirement) {
            case 'covered':
              unawaited(
                h.navigation.currentState!.push<void>(
                  CupertinoPageRoute<void>(
                    builder: (_) => const CupertinoPageScaffold(
                      child: Center(child: Text('Independent cover')),
                    ),
                  ),
                ),
              );
            case 'idle':
              h.interaction.setActive(false);
              await tester.pump();
              h.interaction.setActive(true);
            case 'pin':
              await container.read(pinLockProvider.notifier).setPin('2468');
            case 'account':
              // The queued IME message retains the former client ID. Stop the
              // fake-time cursor before real-zone account persistence; this
              // case measures retired account/submit authority, not whether
              // signOut itself disconnects a focused editor.
              FocusManager.instance.primaryFocus?.unfocus();
              await tester.pumpAndSettle();
              await tester.runAsync(h.fixture.account.signOut);
          }
          await tester.pumpAndSettle();
          final requestsBefore = _fixtureRequests(h);
          final storedBefore = h.fixture.store.value;
          await _lateNext(tester, oldClient);
          oldSubmit();
          await tester.pumpAndSettle();
          expect(_fixtureRequests(h), requestsBefore);
          expect(h.fixture.mutations, isEmpty);
          expect(h.fixture.store.value, same(storedBefore));
          if (retirement == 'covered') {
            expect(find.text('Independent cover'), findsOneWidget);
          }
          if (retirement == 'pin' || retirement == 'idle') {
            expect(find.byType(ServerConnectionScreen), findsNothing);
            expect(find.byType(CupertinoTextField), findsOneWidget);
          }
          if (form != 'login') {
            expect(
              find.byType(CupertinoAlertDialog, skipOffstage: false),
              findsNothing,
            );
          }
          final visibleText = tester
              .widgetList<Text>(find.byType(Text))
              .map((item) => item.data ?? '')
              .join('\n');
          expect(visibleText, isNot(contains(adminPassword)));
          expect(visibleText, isNot(contains('synthetic_admin_access')));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}

int _fixtureRequests(_Harness h) => h.fixture.calls.length;
