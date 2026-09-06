import 'dart:ui' show ViewFocusEvent, ViewFocusState, ViewFocusDirection;
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/configuration_scope.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/core/window/window_policy_models.dart';
import 'package:larenor/core/window/window_policy_providers.dart';
import 'package:larenor/features/backup/data/backup_codec.dart';
import 'package:larenor/features/backup/data/backup_repository.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';
import 'package:larenor/features/backup/presentation/backup_file_access.dart';
import 'package:larenor/features/backup/presentation/backup_screen.dart';
import 'package:larenor/features/settings/data/pin_lock_store.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'backup_test_storage.dart';
import 'prepared_restore_test.dart' as f;

class _Codec extends BackupCodec {
  @override Future<BackupSnapshot> decrypt(Uint8List bytes,String passphrase)async=>f.restoreFixture();
}
class _Files extends BackupFileAccess {
  @override Future<Uint8List?> pick()async=>Uint8List.fromList([1,2,3]);
}
class _Pin extends PinLockStore {
  String? value;
  @override Future<String?> read()async=>value;
}
class _ScreenHarness {
  final storage=MemoryBackupStorage(preferences:{'appearance':'dark'});
  final pin=_Pin();
  int opens=0,disposals=0;
  Future<void> mount(WidgetTester tester)async {
    SharedPreferences.setMockInitialValues({});FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize=const Size(800,1400);tester.view.devicePixelRatio=1;addTearDown(tester.view.reset);
    final probe=Provider<int>((ref){opens++;ref.onDispose(()=>disposals++);return opens;});
    await tester.pumpWidget(ConfigurationScope(child:ProviderScope(overrides:[
      backupRepositoryProvider.overrideWithValue(BackupRepository(storage:storage)),
      backupCodecProvider.overrideWithValue(_Codec()),backupFileAccessProvider.overrideWithValue(_Files()),
      pinLockStoreProvider.overrideWithValue(pin),windowPolicySnapshotProvider.overrideWith((_)=>Stream.value(const WindowPolicySnapshot())),
    ],child:CupertinoApp(localizationsDelegates:AppLocalizations.localizationsDelegates,supportedLocales:AppLocalizations.supportedLocales,
      home:Consumer(builder:(context,ref,_) {ref.watch(probe);return const BackupScreen(freshInstall:true);}),
    ))));
    await flush(tester);
    await tap(tester,'backup-pick');
    await tester.enterText(find.byKey(const ValueKey('backup-restore-passphrase')),'correct backup phrase');
    await tap(tester,'backup-decrypt');await flush(tester);
    await tester.ensureVisible(find.text('Replace selected'));await tester.tap(find.text('Replace selected'));await flush(tester);
  }
  Future<void> confirm(WidgetTester tester)async {
    await tap(tester,'backup-apply');await flush(tester);
  }
  Future<void> accept(WidgetTester tester)async {
    await tester.tap(find.widgetWithText(CupertinoDialogAction,'Restore selected content'));await flush(tester);
  }
}
Future<void> flush(WidgetTester tester)async {for(var i=0;i<12;i++) {await tester.pump(const Duration(milliseconds:50));}}
Future<void> tap(WidgetTester tester,String key)async {
  final finder=find.byKey(ValueKey(key));await tester.ensureVisible(finder);await tester.tap(finder);await flush(tester);
}
void main() {
  testWidgets('actual BackupScreen hands off typed v2 intent and mounts fresh providers', (tester) async {
    final h=_ScreenHarness();await h.mount(tester);await h.confirm(tester);await h.accept(tester);
    expect(h.storage.preferences['appearance'],'light');expect(h.disposals,1);expect(h.opens,2);
    expect(h.storage.writes,contains('secret:backup_restore_journal_v2'));
    expect(h.storage.writes,isNot(contains('secret:${BackupRepository.restoreJournalKey}')));
    expect(h.storage.secrets,isEmpty);expect(tester.takeException(),isNull);
  });
  testWidgets('target changed under retained confirmation has zero writes and no runtime disposal', (tester) async {
    final h=_ScreenHarness();await h.mount(tester);await h.confirm(tester);
    h.storage.preferences['appearance']='system';await h.accept(tester);
    expect(h.storage.preferences['appearance'],'system');expect(h.storage.writes,isEmpty);
  });
  testWidgets('persisted source changed under retained approval cannot retarget Direct restore', (tester) async {
    final h=_ScreenHarness();await h.mount(tester);await h.confirm(tester);
    await SharedPreferencesHomeSourceStore().write(HomeSource.verifiedCore);await h.accept(tester);
    expect(h.storage.preferences['appearance'],'dark');expect(h.storage.writes,isEmpty);
    expect(h.disposals,0);
  });
  for(final event in ['inactive','nativeFocus','pinLoading','pinStore','opaqueRoute']) {
    testWidgets('retained confirmation cannot survive $event retirement and return', (tester) async {
      final h=_ScreenHarness();await h.mount(tester);await h.confirm(tester);
      final screenContext=tester.element(find.byType(BackupScreen));
      final old=tester.widget<CupertinoDialogAction>(find.widgetWithText(CupertinoDialogAction,'Restore selected content')).onPressed!;
      if(event=='inactive') {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      } else if(event=='nativeFocus') {
        tester.binding.handleViewFocusChanged(ViewFocusEvent(viewId:tester.view.viewId,state:ViewFocusState.unfocused,direction:ViewFocusDirection.undefined));
        tester.binding.handleViewFocusChanged(ViewFocusEvent(viewId:tester.view.viewId,state:ViewFocusState.focused,direction:ViewFocusDirection.undefined));
      } else if(event=='pinLoading') {
        ProviderScope.containerOf(screenContext,listen:false).invalidate(pinLockProvider);
      } else if(event=='pinStore') {
        h.pin.value='1234';
      } else {
        final navigator=Navigator.of(screenContext);
        navigator.push(CupertinoPageRoute<void>(builder:(_)=>const CupertinoPageScaffold(child:Text('Covered route'))));
        await flush(tester);navigator.pop();await flush(tester);
      }
      old();await flush(tester);
      expect(h.storage.writes,isEmpty);expect(h.disposals,0);
      expect(tester.takeException(),isNull);
    });
  }

  testWidgets('final confirmation renders the newly prepared target summary and frozen conflict', (tester)async {
    final h=_ScreenHarness();await h.mount(tester);
    h.storage.preferences.remove('appearance');await h.confirm(tester);
    final dialog=find.byType(CupertinoAlertDialog);
    expect(find.descendant(of:dialog,matching:find.text('0 preferences · 0 connected services')),findsOneWidget);
    expect(find.descendant(of:dialog,matching:find.text('Replace selected')),findsOneWidget);
    expect(find.descendant(of:dialog,matching:find.text('Destination: this device.')),findsOneWidget);
    expect(h.storage.writes,isEmpty);
  });

}
