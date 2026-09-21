import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/kiosk/data/launcher_shortcut_api.dart';
import 'package:larenor/features/kiosk/domain/launcher_shortcut_models.dart';
import 'package:larenor/features/kiosk/presentation/launcher_shortcut_runtime_scope.dart';

final class _Api implements LauncherShortcutApi {
  LauncherShortcutAction? initial;
  final events = StreamController<LauncherShortcutAction>.broadcast();
  int takes = 0;
  @override
  Future<LauncherShortcutAction?> takeInitial() async {
    takes++;
    final value = initial;
    initial = null;
    return value;
  }

  @override
  Stream<LauncherShortcutAction> get actions => events.stream;
}

void main() {
  testWidgets('Android visual target on a host never opens native channels', (
    tester,
  ) async {
    if (Platform.isAndroid) return;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final routes = <String>[];
      await tester.pumpWidget(
        CupertinoApp(
          home: LauncherShortcutRuntimeScope(
            navigate: routes.add,
            child: const SizedBox(),
          ),
        ),
      );
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(routes, isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('closed parser rejects unknown and malformed native values', () {
    expect(LauncherShortcutAction.parse('home'), LauncherShortcutAction.home);
    expect(LauncherShortcutAction.parse('kiosk'), LauncherShortcutAction.kiosk);
    for (final value in [
      null,
      '',
      'settings',
      'kiosk/../../home',
      {'action': 'home'},
    ]) {
      expect(LauncherShortcutAction.parse(value), isNull);
    }
    expect(LauncherShortcutAction.kiosk.location, '/settings/kiosk');
  });

  testWidgets('initial and live shortcuts are one-shot foreground navigation', (
    tester,
  ) async {
    final api = _Api()..initial = LauncherShortcutAction.kiosk;
    final routes = <String>[];
    await tester.pumpWidget(
      CupertinoApp(
        home: LauncherShortcutRuntimeScope(
          api: api,
          navigate: routes.add,
          child: const SizedBox(),
        ),
      ),
    );
    await tester.pump();
    expect(routes, ['/settings/kiosk']);
    expect(api.takes, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    api.events.add(LauncherShortcutAction.home);
    await tester.pump();
    expect(routes, ['/settings/kiosk']);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(api.takes, 2);
    api.events.add(LauncherShortcutAction.home);
    await tester.pump();
    expect(routes, ['/settings/kiosk', '/']);

    await tester.pumpWidget(const SizedBox());
    api.events.add(LauncherShortcutAction.kiosk);
    await tester.pump();
    expect(routes, ['/settings/kiosk', '/']);
    await api.events.close();
  });
}
