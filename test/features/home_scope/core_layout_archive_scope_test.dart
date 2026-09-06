import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/core/home_session_controller.dart';
import 'package:larenor/core/window/window_policy_models.dart';
import 'package:larenor/core/window/window_policy_providers.dart';
import 'package:larenor/features/dashboard/data/dashboard_repository.dart';
import 'package:larenor/features/dashboard/providers/dashboard_providers.dart';
import 'package:larenor/features/home_scope/data/home_layout_access.dart';
import 'package:larenor/features/home_scope/presentation/core_layout_archive_file_access.dart';
import 'package:larenor/features/home_scope/presentation/core_layout_archive_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'core_layout_archive_ui_fixture.dart';

void main(){
  testWidgets('same home alive in another ProviderContainer cannot reuse archive State or callbacks',(tester) async {
    final h=ArchiveHarness();await h.mount(tester);
    final otherFiles=ArchiveFiles();
    final second=ProviderContainer(overrides:[
      homeSessionControllerProvider.overrideWithValue(h.home),
      homeLayoutClockProvider.overrideWithValue(()=>h.session.now),
      dashboardRepositoryProvider.overrideWithValue(DashboardRepository.core(scope:h.repository.scope!,isCurrent:()=>true)),
      coreLayoutArchiveFileAccessProvider.overrideWithValue(otherFiles),
      windowPolicySnapshotProvider.overrideWith((_)=>Stream.value(const WindowPolicySnapshot())),
    ]);
    addTearDown(second.dispose);
    var current=h.container;late StateSetter rebuild;final key=GlobalKey();
    await tester.pumpWidget(CupertinoApp(localizationsDelegates:AppLocalizations.localizationsDelegates,supportedLocales:AppLocalizations.supportedLocales,
      home:StatefulBuilder(builder:(_,setState){rebuild=setState;return UncontrolledProviderScope(container:current,child:AppInteractionScope(controller:h.home.interaction,child:CoreLayoutArchiveScreen(key:key,gateCurrent:()=>true,runFileDialog:<T>(operation)=>operation())));}),
    ));await flush(tester);
    await tester.enterText(find.byKey(const ValueKey('core-layout-archive-password')),'sensitive draft');
    final oldState=key.currentState;
    final held=tester.widget<CupertinoButton>(find.byKey(const ValueKey('core-layout-archive-pick'))).onPressed!;
    rebuild(()=>current=second);await flush(tester);expect(key.currentState,same(oldState));
    held();await flush(tester);
    expect(h.files.picks,0);expect(otherFiles.picks,0);expect(find.text('sensitive draft'),findsNothing);
    expect(find.byKey(const ValueKey('core-layout-archive-pick')),findsNothing);
    expect(h.home.account.session,isNotNull);expect(h.home.interaction.active,isTrue);
  });
}
