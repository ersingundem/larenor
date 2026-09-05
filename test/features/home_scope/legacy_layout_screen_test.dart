import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/core/home_data_scope.dart';
import 'package:larenor/features/dashboard/data/dashboard_repository.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/features/dashboard/providers/dashboard_providers.dart';
import 'package:larenor/features/home_scope/data/home_layout_access.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/shared/widgets/settings_action_tile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/home_source_store.dart';

import '../../core/home_scope_fixture.dart';

const localLayout = DashboardLayout(rooms: [
  DashboardRoom(id: 'private-room-id', name: 'Kitchen', entityIds: ['light.private']),
  DashboardRoom(id: 'second-private', name: 'Living room'),
]);
final scopeA = HomeDataScope.fromJson({'coreId': 'a' * 32, 'homeId': 'b' * 32, 'userId': 'one'});
Future<void> layoutPress(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(finder, 300, scrollable: find.byType(Scrollable).last);
    await flush(tester);
  }
  await press(tester, key);
}
Future<void> openPreview(WidgetTester tester, ScopeHarness h, {String language = 'en'}) async {
  h.router(tester).push('/settings/home-source');
  await flush(tester);
  await tester.enterText(find.byType(CupertinoTextField), '1234');
  await tester.tap(find.text(language == 'tr' ? 'Kilidi Aç' : 'Unlock'));
  await flush(tester);
  await layoutPress(tester, 'home-layout-preview-entry');
  expect(find.byKey(const ValueKey('home-layout-preview-screen')), findsOneWidget);
}
DashboardRepository repository(WidgetTester tester, ScopeHarness h) {
  final subscription = h.runtime(tester).listen(dashboardRepositoryProvider, (_, _) {});
  addTearDown(subscription.close);
  return subscription.read();
}
class CopyPlatform extends InMemorySharedPreferencesStore {
  CopyPlatform(Map<String, Object> values) : super.withData({for (final entry in values.entries) 'flutter.${entry.key}': entry.value});
  bool commit = false, throwing = false;
  int copies = 0;
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (!key.startsWith('flutter.dashboard_layout_core_v1_')) return super.setValue(valueType, key, value);
    copies++;
    if (commit) await super.setValue(valueType, key, value);
    if (throwing) throw StateError('private diagnostic');
    return false;
  }
}
void main() {
  testWidgets(
    'verified Core offers explicit local layout preview only behind PIN',
    (tester) async {
      final h = ScopeHarness(HomeSource.verifiedCore);
      await h.mount(tester, pin: '1234');
      await h.signIn();
      await flush(tester);
      h.router(tester).push('/settings/home-source');
      await flush(tester);
      expect(
        find.byKey(const ValueKey('home-layout-preview-entry')),
        findsNothing,
      );
      await tester.enterText(find.byType(CupertinoTextField), '1234');
      await tester.tap(find.text('Unlock'));
      await flush(tester);
      expect(
        find.byKey(const ValueKey('home-layout-preview-entry')),
        findsOneWidget,
      );
      expect(h.connectionReads, 0);
    },
  );

  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets('actual PIN preview and selected copy $language $width at 2x', (tester) async {
        final h = ScopeHarness(HomeSource.verifiedCore);
        await h.mount(tester, pin: '1234', locale: language, width: width, scale: 2,
            preferences: {'dashboard_layout': jsonEncode(localLayout.toJson())});
        await h.signIn(); await flush(tester);
        expect((await repository(tester, h).load()).rooms, isEmpty);
        expect(h.connectionReads, 0);
        await openPreview(tester, h, language: language);
        final choose = find.byKey(const ValueKey('home-layout-room-0'));
        if (choose.evaluate().isEmpty) await tester.scrollUntilVisible(choose, 300, scrollable: find.byType(Scrollable).last);
        await tester.ensureVisible(choose); await flush(tester);
        expect(tester.getSize(choose).height, greaterThanOrEqualTo(48));
        await tester.tap(choose); await flush(tester);
        final semantics = tester.ensureSemantics();
        expect(tester.getSemantics(choose), matchesSemantics(isButton: true, isEnabled: true, hasEnabledState: true,
          isFocusable: true, isSelected: true, hasSelectedState: true, hasTapAction: true, hasFocusAction: true, label: 'Kitchen'));
        semantics.dispose();
        await layoutPress(tester, 'home-layout-copy-selected');
        expect(find.byType(CupertinoAlertDialog), findsOneWidget);
        await layoutPress(tester, 'home-layout-confirm-copy');
        expect(find.byKey(const ValueKey('home-layout-copy-complete')), findsOneWidget);
        final stored = await repository(tester, h).load();
        expect(stored.rooms.map((r) => r.name), ['Kitchen']);
        expect(stored.rooms.single.entityIds, isEmpty);
        expect(stored.rooms.single.id, isNot('private-room-id'));
        expect(await DashboardRepository().load(), localLayout);
        expect(h.connectionReads, 0); expect(h.rest.reads, 0);
        expect(tester.takeException(), isNull);
      });
    }
  }
  for (final change in ['logout', 'user', 'home', 'source', 'pending', 'background', 'idle', 'expiry']) {
    testWidgets('captured confirmation cannot copy after $change', (tester) async {
      final h = ScopeHarness(HomeSource.verifiedCore);
      await h.mount(tester, pin: '1234', preferences: {'dashboard_layout': jsonEncode(localLayout.toJson())});
      await h.signIn(); await flush(tester); await openPreview(tester, h);
      await layoutPress(tester, 'home-layout-room-0');
      await layoutPress(tester, 'home-layout-copy-selected');
      final action = tester.widget<CupertinoDialogAction>(find.byKey(const ValueKey('home-layout-confirm-copy'))).onPressed!;
      Future<void>? pending;
      switch (change) {
        case 'logout': await h.account.signOut();
        case 'user': await h.account.signOut(); h.api.userId = 'two'; await h.signIn();
        case 'home': await h.account.signOut(); h.api.homeId = 'c' * 32; await h.signIn();
        case 'source': await h.home(tester).choose(HomeSource.directLocal);
        case 'pending':
          h.api.pendingContext = Completer<ServerContext>();
          h.now = h.account.session!.expiresAt.subtract(const Duration(seconds: 20));
          pending = h.account.ensureSession().then<void>((_) {}); await flush(tester);
          expect(h.account.hasPendingContext, isTrue);
        case 'background': tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        case 'idle': AppInteractionScope.maybeRead(tester.element(find.byKey(const ValueKey('home-layout-preview-screen'))))!.setActive(false);
        case 'expiry': h.now = h.account.session!.expiresAt.subtract(const Duration(seconds: 29));
      }
      action(); await flush(tester);
      final prefs = await SharedPreferences.getInstance(); await prefs.reload();
      expect(prefs.get(scopeA.storageKey), isNull);
      expect(prefs.getString('dashboard_layout'), jsonEncode(localLayout.toJson()));
      if (pending != null) { h.api.pendingContext!.complete(h.api.identity); await pending; await flush(tester); }
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('refresh intent without working=true closes old access, same tuple later keeps key', (tester) async {
    final h = ScopeHarness(HomeSource.verifiedCore);
    await h.mount(tester, pin: '1234'); await h.signIn(); await flush(tester);
    final old = repository(tester, h);
    await old.save(localLayout);
    final access = homeLayoutAccess(h.home(tester), clock: () => h.now)!;
    h.now = h.account.session!.expiresAt.subtract(const Duration(seconds: 20));
    h.api.pendingContext = Completer<ServerContext>();
    final pending = h.account.ensureSession();
    expect(h.account.working, isFalse);
    expect(access.isCurrent, isFalse);
    await expectLater(old.load(), throwsA(isA<DashboardStorageException>()));
    await flush(tester);
    expect(h.account.hasPendingContext, isTrue);
    await expectLater(repository(tester, h).load(), throwsA(isA<DashboardStorageException>()));
    h.now = DateTime.now();
    h.api.pendingContext!.complete(h.api.identity); await pending; await flush(tester);
    final fresh = repository(tester, h);
    expect(fresh.scope, scopeA);
    expect(await fresh.load(), localLayout);
    expect(access.isCurrent, isFalse);
  });

  testWidgets('saved scope survives app remount while other Core home stays empty', (tester) async {
    final h = ScopeHarness(HomeSource.verifiedCore);
    await h.mount(tester, pin: '1234', preferences: {'dashboard_layout': jsonEncode(localLayout.toJson())});
    await h.signIn(); await flush(tester); await openPreview(tester, h);
    await layoutPress(tester, 'home-layout-room-0');
    await layoutPress(tester, 'home-layout-copy-selected');
    await layoutPress(tester, 'home-layout-confirm-copy');
    final prefs = await SharedPreferences.getInstance(); await prefs.reload();
    final persisted = {for (final key in prefs.getKeys()) key: prefs.get(key)!};
    await tester.pumpWidget(const SizedBox.shrink()); await flush(tester);
    final restored = ScopeHarness(HomeSource.verifiedCore)..store.value = h.store.value;
    await restored.mount(tester, pin: '1234', preferences: persisted);
    expect(restored.api.meReads, 1); expect(restored.api.contextReads, 1);
    expect((await repository(tester, restored).load()).rooms.map((r) => r.name), ['Kitchen']);
    restored.api.homeId = 'c' * 32;
    restored.now = restored.account.session!.expiresAt.subtract(const Duration(seconds: 20));
    final refreshing = restored.account.ensureSession();
    restored.now = DateTime.now(); await refreshing; await flush(tester);
    expect((await repository(tester, restored).load()).rooms, isEmpty);
    expect((await SharedPreferences.getInstance()).getString(scopeA.storageKey), persisted[scopeA.storageKey]);
    expect(restored.connectionReads, 0);
  });
  testWidgets('Direct repository stays legacy when a Server account signs in', (tester) async {
    final h = ScopeHarness(HomeSource.directLocal);
    await h.mount(tester, preferences: {'dashboard_layout': jsonEncode(localLayout.toJson())});
    final before = repository(tester, h);
    expect(before.scope, isNull); expect(await before.load(), localLayout);
    await h.signIn(); await flush(tester);
    expect(identical(before, repository(tester, h)), isTrue);
    expect(await before.load(), localLayout);
    expect((await SharedPreferences.getInstance()).get(scopeA.storageKey), isNull);
  });
  testWidgets('keyboard selection, cancel and hidden route invalidate captured action', (tester) async {
    final h = ScopeHarness(HomeSource.verifiedCore);
    await h.mount(tester, pin: '1234', preferences: {'dashboard_layout': jsonEncode(localLayout.toJson())});
    await h.signIn(); await flush(tester); await openPreview(tester, h);
    final choose = find.byKey(const ValueKey('home-layout-room-0'));
    await tester.ensureVisible(choose); await flush(tester);
    final button = find.descendant(of: choose, matching: find.byType(CupertinoButton));
    final focus = Focus.of(tester.element(find.descendant(of: button, matching: find.byType(Text)).first));
    focus.requestFocus(); await flush(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.space); await flush(tester);
    expect(tester.widget<SettingsActionTile>(choose).selected, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab); await flush(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft); await flush(tester);
    expect(focus.hasFocus, isTrue);
    await layoutPress(tester, 'home-layout-copy-selected');
    await tester.tap(find.text('Cancel')); await flush(tester);
    expect((await SharedPreferences.getInstance()).get(scopeA.storageKey), isNull);
    final old = tester.widget<SettingsActionTile>(find.byKey(const ValueKey('home-layout-copy-selected'))).onTap!;
    final navigator = Navigator.of(tester.element(choose));
    navigator.push(CupertinoPageRoute<void>(builder: (_) => const CupertinoPageScaffold(child: Text('Other local page'))));
    await flush(tester); old(); await flush(tester);
    expect(find.byType(CupertinoAlertDialog), findsNothing);
    navigator.pop(); await flush(tester); old(); await flush(tester);
    expect(find.byType(CupertinoAlertDialog), findsNothing);
    expect((await SharedPreferences.getInstance()).get(scopeA.storageKey), isNull);
  });
  for (final commit in [false, true]) {
    for (final throwing in [false, true]) {
      testWidgets('uncertain copy $commit/$throwing never confirms or automatically retries', (tester) async {
        final h = ScopeHarness(HomeSource.verifiedCore);
        await h.mount(tester, pin: '1234', preferences: {'dashboard_layout': jsonEncode(localLayout.toJson())});
        await h.signIn(); await flush(tester);
        final initial = await SharedPreferences.getInstance();
        final values = {for (final key in initial.getKeys()) key: initial.get(key)!};
        SharedPreferences.resetStatic();
        final platform = CopyPlatform(values)..commit = commit..throwing = throwing;
        SharedPreferencesStorePlatform.instance = platform;
        await openPreview(tester, h);
        await layoutPress(tester, 'home-layout-room-0');
        await layoutPress(tester, 'home-layout-copy-selected');
        final stale = tester.widget<CupertinoDialogAction>(find.byKey(const ValueKey('home-layout-confirm-copy'))).onPressed!;
        await layoutPress(tester, 'home-layout-confirm-copy');
        expect(find.byKey(const ValueKey('home-layout-copy-complete')), findsNothing);
        expect(find.textContaining('save could not be confirmed'), findsOneWidget);
        expect(platform.copies, 1);
        // Once a dialog completed, its captured callback cannot act on a later route.
        stale(); await flush(tester);
        expect(platform.copies, 1);
        await layoutPress(tester, 'home-layout-refresh-preview');
        final current = find.byKey(const ValueKey('home-layout-current-room-0'));
        expect(current, commit ? findsOneWidget : findsNothing);
        expect(platform.copies, 1);
      });
    }
  }
}
