import 'package:flutter/cupertino.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/sound_events/data/sound_event_controller.dart';
import 'package:larenor/features/sound_events/domain/sound_event_models.dart';
import 'package:larenor/features/sound_events/presentation/sound_event_screen.dart';

import 'sound_event_controller_test.dart' as fixture;

void main() {
  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1280.0]) {
      testWidgets(
        '${locale.languageCode} $width at 2x is keyboard and TalkBack ready',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 1100);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          final controller = SoundEventController(
            api: _ReadyApi(),
            authority: fixture.authority(),
            isCurrent: () => true,
          );
          await tester.pumpWidget(
            CupertinoApp(
              locale: locale,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: SoundEventScreen(controller: controller),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('sound-event-status-filter')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('sound-event-class-filter')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('sound-event-acknowledge')),
            findsOneWidget,
          );
          final semantics = tester.getSemantics(
            find.byKey(const ValueKey('sound-event-acknowledge')),
          );
          expect(
            semantics.getSemanticsData().hasAction(SemanticsAction.tap),
            isTrue,
          );
          expect(
            tester
                .getSize(find.byKey(const ValueKey('sound-event-acknowledge')))
                .height,
            greaterThanOrEqualTo(48),
          );
          controller.dispose();
        },
      );
    }
  }
}

final class _ReadyApi implements SoundEventApi {
  @override
  Future<SoundEventSnapshot> load(
    SoundEventAuthority expected,
    SoundEventFilter filter,
  ) async => fixture.snapshot(acknowledged: false);

  @override
  Future<SoundEventAcknowledgement> acknowledge(
    SoundEventAuthority expected,
    SoundEventSnapshot current,
    SoundEventItem event,
  ) => throw UnimplementedError();
}
