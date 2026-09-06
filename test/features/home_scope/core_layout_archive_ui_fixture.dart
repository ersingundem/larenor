import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/core/home_session_controller.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/core/window/window_policy_models.dart';
import 'package:larenor/core/window/window_policy_providers.dart';
import 'package:larenor/features/dashboard/data/dashboard_repository.dart';
import 'package:larenor/features/dashboard/providers/dashboard_providers.dart';
import 'package:larenor/features/home_scope/data/home_layout_access.dart';
import 'package:larenor/features/settings/data/pin_lock_store.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';
import 'package:larenor/features/home_scope/presentation/core_layout_archive_file_access.dart';
import 'package:larenor/features/settings/presentation/settings_gate_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import '../../core/home_scope_fixture.dart';
export '../../core/home_scope_fixture.dart' show flush, press;

class ArchiveFiles extends CoreLayoutArchiveFileAccess {
  Uint8List? input, output;
  Future<Uint8List?> Function()? onPick;
  Future<Uri?> Function()? onSave;
  int picks=0, saves=0;
  @override Future<Uint8List?> pick() async { picks++; return onPick==null ? input : await onPick!(); }
  @override Future<Uri?> save(Uint8List bytes) async { saves++; output=Uint8List.fromList(bytes); return onSave==null ? Uri.parse('content://synthetic/export') : await onSave!(); }
}

class ArchiveHarness {
  final session=ScopeHarness(HomeSource.verifiedCore);
  final files=ArchiveFiles();
  late HomeSessionController home;
  late ProviderContainer container;
  final navigator=GlobalKey<NavigatorState>();
  final boundary=GlobalKey();
  Future<void> mount(WidgetTester tester,{String language='en',double width=600,double scale=1,String? pin='1234',PinLockStore? pinStore}) async {
    SharedPreferences.setMockInitialValues({'dashboard_layout':'legacy-private','unrelated':'unchanged'});
    FlutterSecureStorage.setMockInitialValues({'settings_pin':?pin});
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.view.devicePixelRatio=1; tester.view.physicalSize=Size(width,1000);
    tester.platformDispatcher.textScaleFactorTestValue=scale;
    addTearDown(tester.view.reset); addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await session.account.initialize(); await session.signIn();
    home=HomeSessionController(store:session.source,account:session.account);
    await home.initialize(); home.runtimeMounted(home.runtimeIdentity);
    container=ProviderContainer(overrides:[
      homeSessionControllerProvider.overrideWithValue(home),
      homeLayoutClockProvider.overrideWithValue(()=>session.now),
      coreLayoutArchiveFileAccessProvider.overrideWithValue(files),
      if(pinStore!=null)pinLockStoreProvider.overrideWithValue(pinStore),
      windowPolicySnapshotProvider.overrideWith((_)=>Stream.value(const WindowPolicySnapshot(supported:true,isResumed:true,hasWindowFocus:true))),
    ]);
    // The actual scoped repository/provider stays alive through route changes.
    container.listen(dashboardRepositoryProvider,(_,_){});
    await tester.pumpWidget(RepaintBoundary(key:boundary,child:UncontrolledProviderScope(container:container,child:AppInteractionScope(controller:home.interaction,child:CupertinoApp(
      navigatorKey:navigator,locale:Locale(language),localizationsDelegates:AppLocalizations.localizationsDelegates,supportedLocales:AppLocalizations.supportedLocales,
      home:const SettingsGateScreen(initialDestination:SettingsGateDestination.homeSource),
    )))));
    await flush(tester);
    addTearDown(() async { await tester.pumpWidget(const SizedBox.shrink()); await tester.pump();container.dispose();home.dispose();session.account.dispose(); });
  }
  DashboardRepository get repository=>container.read(dashboardRepositoryProvider);
  Future<void> open(WidgetTester tester,{String language='en'}) async {
    await tester.enterText(find.byType(CupertinoTextField),'1234');
    await tester.tap(find.text(language=='tr'?'Kilidi Aç':'Unlock'));await flush(tester);
    await archivePress(tester,'core-layout-archive-entry');
  }
}
Future<void> archiveVisible(WidgetTester tester,String key) async {
  final finder=find.byKey(ValueKey(key));
  if(finder.evaluate().isEmpty) await tester.scrollUntilVisible(finder,250,scrollable:find.byType(Scrollable).first);
  await tester.ensureVisible(finder);await flush(tester);
}
Future<void> archivePress(WidgetTester tester,String key) async {
  await archiveVisible(tester,key);await press(tester,key);
}
