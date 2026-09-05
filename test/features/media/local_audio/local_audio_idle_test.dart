import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/media/local_audio/presentation/local_audio_screen.dart';
import 'package:larenor/features/media/local_audio/providers/local_audio_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import 'local_audio_ui_fixture.dart';

void main() {
  testWidgets(
    'idle and wake during a pending source read cannot send the old pause',
    (tester) async {
      final interaction = AppInteractionController();
      final bridge = FakeLocalAudioBridge()..current = audioState();
      addTearDown(interaction.dispose);
      addTearDown(bridge.events.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [localAudioBridgeProvider.overrideWithValue(bridge)],
          child: CupertinoApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (_, child) =>
                AppInteractionScope(controller: interaction, child: child!),
            home: const LocalAudioScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      bridge.snapshotGate = Completer<void>();
      await tester.tap(find.text('Pause'));
      await tester.pump();
      expect(bridge.snapshotReads, 1);
      interaction.setActive(false);
      await tester.pump();
      expect(
        bridge.commands,
        isEmpty,
        reason: 'idle must not stop ongoing native audio',
      );
      interaction.setActive(true);
      await tester.pump();
      bridge.snapshotGate!.complete();
      await tester.pumpAndSettle();
      expect(bridge.commands, isEmpty);
      await tester.tap(find.text('Pause'));
      await tester.pumpAndSettle();
      expect(bridge.commands, ['pause']);
      expect(tester.takeException(), isNull);
    },
  );
}
