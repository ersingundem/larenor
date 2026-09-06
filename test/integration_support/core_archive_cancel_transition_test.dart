import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/home_scope/data/core_layout_archive_codec.dart';

import '../../integration_test/support/app_harness.dart' show tapVisible;
import '../../integration_test/support/core_archive_journey.dart';
import '../features/home_scope/core_layout_archive_screen_test.dart'
    show archive, importArchive, passphrase;
import '../features/home_scope/core_layout_archive_ui_fixture.dart';

void main() {
  late Uint8List encrypted;
  setUpAll(() async {
    encrypted = await const CoreLayoutArchiveCodec().encrypt(
      archive(),
      passphrase,
    );
  });
  for (final dilation in [1.0, 4.0]) {
    testWidgets(
      'archive journey awaits actual cancelled route disposal at dilation $dilation',
      (tester) async {
        final originalDilation = timeDilation;
        try {
          final h = ArchiveHarness();
          await h.mount(tester);
          await h.open(tester);
          await importArchive(tester, h, encrypted);
          final before = await h.repository.readSnapshot();
          await archivePress(tester, 'core-layout-archive-replace');
          await tester.pumpAndSettle();
          final cancel = find.byKey(
            const ValueKey('core-layout-archive-confirm-cancel'),
          );
          final retained = tester
              .widget<CupertinoDialogAction>(cancel)
              .onPressed!;
          timeDilation = dilation;
          // The same single tap and fixed post-tap pump used by the native journey.
          await tapVisible(tester, cancel);
          // Cancellation has already popped the route; only its removal is pending.
          expect(ModalRoute.of(tester.element(cancel))?.isCurrent, isFalse);
          await coreArchiveJourneyConfirmationDismissed(tester);
          expect(find.byType(CupertinoAlertDialog), findsNothing);
          final preview = find.byKey(
            const ValueKey('core-layout-archive-preview'),
          );
          expect(preview, findsOneWidget);
          expect(ModalRoute.of(tester.element(preview))?.isCurrent, isTrue);
          expect(
            (await h.repository.readSnapshot()).fingerprint,
            before.fingerprint,
          );
          retained();
          await tester.pump();
          expect(
            (await h.repository.readSnapshot()).fingerprint,
            before.fingerprint,
          );
          expect(h.files.saves, 0);
          expect(h.session.connectionReads, 0);
          expect(tester.takeException(), isNull);
        } finally {
          timeDilation = originalDilation;
        }
      },
    );
  }
}
