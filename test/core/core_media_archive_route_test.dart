import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/home_scope/presentation/core_home_status_screen.dart';
import 'package:larenor/features/media/archive_health/presentation/media_archive_health_card.dart';

import 'home_scope_fixture.dart';

void main() {
  testWidgets(
    'verified Core exposes archive health without direct media credentials',
    (tester) async {
      final harness = ScopeHarness(HomeSource.verifiedCore);
      await harness.mount(tester);
      await harness.signIn();
      await flush(tester);

      expect(find.byType(CoreHomeStatusScreen), findsOneWidget);
      await press(tester, 'core-home-media-archive-action');

      expect(find.byType(MediaArchiveHealthCard), findsOneWidget);
      expect(harness.connectionReads, 0);

      await harness.account.signOut();
      await flush(tester);

      expect(find.byType(MediaArchiveHealthCard), findsNothing);
      expect(find.byType(CoreHomeStatusScreen), findsOneWidget);
      expect(harness.connectionReads, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
