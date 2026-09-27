import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/private_event_sharing/data/private_event_share_api.dart';
import 'package:larenor/features/private_event_sharing/data/private_event_share_controller.dart';
import 'package:larenor/features/private_event_sharing/domain/private_event_share_models.dart';
import 'package:larenor/features/private_event_sharing/presentation/private_event_share_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

final class _RetryApi implements PrivateEventShareApi {
  int snapshotCalls = 0;

  @override
  Future<EventShareSnapshot> snapshot() async {
    snapshotCalls++;
    if (snapshotCalls == 1) throw TimeoutException('offline');
    return EventShareSnapshot(
      revision: 1,
      shares: const [],
      audit: const [],
      auditTruncated: false,
    );
  }

  @override
  Future<CreatedPrivateEventShare> create({
    required int expectedRevision,
    required String commandId,
    required EventShareDraft draft,
    required EventRedactionPreview preview,
  }) => throw UnimplementedError();

  @override
  Future<EventShareDownload> download({
    required String accessToken,
    required String accessId,
  }) => throw UnimplementedError();

  @override
  Future<EventRedactionPreview> preview(EventShareDraft draft) =>
      throw UnimplementedError();

  @override
  Future<void> revoke({
    required int expectedRevision,
    required String commandId,
    required String shareId,
  }) => throw UnimplementedError();
}

Future<void> _pump(
  WidgetTester tester, {
  required String language,
  required PrivateEventShareController controller,
}) async {
  await tester.pumpWidget(
    CupertinoApp(
      locale: Locale(language),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: PrivateEventShareScreen(controller: controller),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final language in ['en', 'tr']) {
    testWidgets(
      'localized share screen retries an offline snapshot in $language',
      (tester) async {
        final api = _RetryApi();
        final controller = PrivateEventShareController(
          api,
          commandIds: () => 'command-id',
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          controller.dispose();
        });
        await _pump(tester, language: language, controller: controller);

        if (language == 'tr') {
          expect(find.text('Özel olay paylaşımı'), findsOneWidget);
          expect(find.text('Alıcı ve amaç'), findsOneWidget);
        } else {
          expect(find.text('Private event sharing'), findsOneWidget);
          expect(find.text('Recipient and purpose'), findsOneWidget);
        }
        expect(controller.state, EventShareState.offline);
        await tester.drag(find.byType(ListView), const Offset(0, -500));
        await tester.pumpAndSettle();
        expect(
          find.text(
            language == 'tr' ? 'Core kullanılamıyor' : 'Core unavailable',
          ),
          findsWidgets,
        );
        expect(
          find.byKey(const ValueKey('private-event-share-retry')),
          findsWidgets,
        );

        await tester.tap(
          find.byKey(const ValueKey('private-event-share-retry')).first,
        );
        await tester.pumpAndSettle();

        expect(api.snapshotCalls, 2);
        expect(controller.state, EventShareState.ready);
        expect(
          find.text(language == 'tr' ? 'Henüz öğe yok' : 'No items yet'),
          findsWidgets,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
