import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/hub/presentation/media_session_state.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_config.dart';
import 'package:larenor/features/media/jellyfin/providers/jellyfin_providers.dart';

const _first = JellyfinConfig(
  baseUrl: 'http://first.invalid',
  userId: 'one',
  accessToken: 'test-first',
  deviceId: 'test-device',
);
const _second = JellyfinConfig(
  baseUrl: 'http://second.invalid',
  userId: 'two',
  accessToken: 'test-second',
  deviceId: 'test-device',
);

class _Connection extends JellyfinConnection {
  @override
  Future<JellyfinConfig?> build() async => _first;
  void replace(JellyfinConfig? config) => state = AsyncData(config);
  void refreshStart() => state = const AsyncLoading();
  void fail() =>
      state = AsyncError(StateError('private-detail'), StackTrace.empty);
}

class _Probe extends ConsumerStatefulWidget {
  const _Probe(this.onAction);
  final VoidCallback onAction;
  @override
  ConsumerState<_Probe> createState() => _ProbeState();
}

class _ProbeState extends MediaSessionState<_Probe> {
  @override
  Widget build(BuildContext context) {
    watchMediaAccounts(jellyfinOnly: true);
    return CupertinoPageScaffold(
      child: Column(
        children: [
          Text(
            sessionExpired
                ? 'Expired'
                : foreground
                ? 'Account title'
                : 'Hidden',
          ),
          CupertinoButton(
            onPressed: guardedMediaAction(widget.onAction),
            child: const Text('Action'),
          ),
        ],
      ),
    );
  }
}

void main() {
  Future<_Connection> mount(WidgetTester tester, VoidCallback action) async {
    final connection = _Connection();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [jellyfinConnectionProvider.overrideWith(() => connection)],
        child: CupertinoApp(home: _Probe(action)),
      ),
    );
    await tester.pumpAndSettle();
    return connection;
  }

  testWidgets(
    'initial async configuration load establishes the session without expiring it',
    (tester) async {
      var calls = 0;
      await mount(tester, () => calls++);
      expect(find.text('Account title'), findsOneWidget);
      await tester.tap(find.text('Action'));
      expect(calls, 1);
    },
  );

  testWidgets('a captured callback cannot act after account replacement', (
    tester,
  ) async {
    var calls = 0;
    final connection = await mount(tester, () => calls++);
    final callback = tester
        .widget<CupertinoButton>(find.byType(CupertinoButton))
        .onPressed!;
    connection.replace(_second);
    await tester.pump();
    callback();
    expect(find.text('Expired'), findsOneWidget);
    expect(find.text('Account title'), findsNothing);
    expect(calls, 0);
  });

  testWidgets('disconnect or read error invalidates existing route evidence', (
    tester,
  ) async {
    var calls = 0;
    final connection = await mount(tester, () => calls++);
    connection.replace(null);
    await tester.pump();
    await tester.tap(find.text('Action'));
    connection.fail();
    await tester.pump();
    expect(find.text('Expired'), findsOneWidget);
    expect(find.textContaining('private-detail'), findsNothing);
    expect(calls, 0);
  });

  testWidgets('app switching invalidates old interactions before frames stop', (
    tester,
  ) async {
    var calls = 0;
    await mount(tester, () => calls++);
    final callback = tester
        .widget<CupertinoButton>(find.byType(CupertinoButton))
        .onPressed!;
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }
    expect(find.text('Account title'), findsNothing);
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }
    callback();
    expect(calls, 0);
    await tester.tap(find.text('Action'));
    expect(calls, 1);
  });

  testWidgets(
    'equivalent config reread recovers the page while old callbacks remain invalid',
    (tester) async {
      var calls = 0;
      final connection = await mount(tester, () => calls++);
      final callback = tester
          .widget<CupertinoButton>(find.byType(CupertinoButton))
          .onPressed!;
      connection.refreshStart();
      await tester.pump();
      expect(find.text('Expired'), findsOneWidget);
      connection.replace(
        JellyfinConfig(
          baseUrl: _first.baseUrl,
          userId: _first.userId,
          accessToken: _first.accessToken,
          deviceId: _first.deviceId,
        ),
      );
      await tester.pump();
      expect(find.text('Account title'), findsOneWidget);
      callback();
      expect(calls, 0);
      await tester.tap(find.text('Action'));
      expect(calls, 1);
    },
  );

  testWidgets('captured callback after disposal is a no-op', (tester) async {
    var calls = 0;
    await mount(tester, () => calls++);
    final callback = tester
        .widget<CupertinoButton>(find.byType(CupertinoButton))
        .onPressed!;
    await tester.pumpWidget(const SizedBox());
    callback();
    expect(calls, 0);
    expect(tester.takeException(), isNull);
  });
}
