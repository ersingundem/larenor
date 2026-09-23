import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/home_scope/presentation/core_home_status_screen.dart';
import 'package:larenor/features/media/music/presentation/music_center_screen.dart';
import 'package:larenor/features/server/music_manager/presentation/server_music_manager_screen.dart';

import 'home_scope_fixture.dart';

void main() {
  testWidgets(
    'verified Core music uses the Core manager and retires on authority loss',
    (tester) async {
      final harness = ScopeHarness(HomeSource.verifiedCore);
      await harness.mount(tester);
      await harness.signIn();
      await flush(tester);

      expect(find.byType(CoreHomeStatusScreen), findsOneWidget);
      await press(tester, 'core-home-music-action');

      expect(find.byType(ServerMusicManagerScreen), findsOneWidget);
      expect(find.byType(MusicCenterScreen), findsNothing);
      expect(harness.connectionReads, 0);

      await harness.account.signOut();
      await flush(tester);

      expect(find.byType(ServerMusicManagerScreen), findsNothing);
      expect(find.byType(CoreHomeStatusScreen), findsOneWidget);
      expect(harness.connectionReads, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
