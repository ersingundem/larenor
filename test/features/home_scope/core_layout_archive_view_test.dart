import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/home_scope/data/core_layout_archive_codec.dart';
import 'package:larenor/features/home_scope/presentation/core_layout_archive_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'core_layout_archive_ui_fixture.dart';
import 'core_layout_archive_screen_test.dart' show archive,scope,passphrase,importArchive;

class _View extends TestFlutterView {
  _View(TestFlutterView source):super(view:source,platformDispatcher:source.platformDispatcher,display:source.display);
  @override int get viewId=>100;
  // A synthetic second view has no matching native engine surface.
  @override void render(ui.Scene scene,{ui.Size? size}){}
  @override void updateSemantics(ui.SemanticsUpdate update){}
}
void main(){
  testWidgets('same provider and navigator moved to a different native View cannot reuse confirmation',(tester) async {
    final h=ArchiveHarness();await h.mount(tester);
    final bytes=await tester.runAsync(()=>const CoreLayoutArchiveCodec().encrypt(archive(),passphrase));
    final appKey=GlobalKey(),screenKey=GlobalKey();
    ui.FlutterView current=tester.view;
    Widget app()=>View(view:current,child:UncontrolledProviderScope(container:h.container,child:AppInteractionScope(controller:h.home.interaction,child:CupertinoApp(
      key:appKey,localizationsDelegates:AppLocalizations.localizationsDelegates,supportedLocales:AppLocalizations.supportedLocales,
      home:CoreLayoutArchiveScreen(key:screenKey,gateCurrent:()=>true,runFileDialog:<T>(operation)=>operation()),
    ))));
    await tester.pumpWidget(app(),wrapWithView:false);await flush(tester);
    await importArchive(tester,h,bytes!);await archivePress(tester,'core-layout-archive-replace');
    final state=screenKey.currentState;
    final held=tester.widget<CupertinoDialogAction>(find.byKey(const ValueKey('core-layout-archive-confirm'))).onPressed!;
    current=_View(tester.view);
    await tester.pumpWidget(app(),wrapWithView:false);await flush(tester);
    expect(screenKey.currentState,same(state));expect(View.of(screenKey.currentContext!).viewId,100);
    held();await flush(tester);
    final prefs=await SharedPreferences.getInstance();await prefs.reload();expect(prefs.getString(scope.storageKey),isNull);
    expect(find.byKey(const ValueKey('core-layout-archive-confirm')),findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());await flush(tester);
  });
}
