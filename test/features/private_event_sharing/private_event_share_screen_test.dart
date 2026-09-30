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

final class _SetupApi
    implements PrivateEventShareApi, PrivateEventShareSetupApi {
  static const admin = '11111111111111111111111111111111';
  static const recipient = '22222222222222222222222222222222';
  bool configured = false;
  int consents = 0, previews = 0;

  PrivateEventSharePolicy get _policy => PrivateEventSharePolicy(
    revision: configured ? 1 : 0,
    configured: configured,
    active: configured,
    grantorIds: configured ? const [admin] : const [],
    recipientIds: configured ? const [recipient] : const [],
    purposes: configured ? const ['incident review'] : const [],
    accessModes: configured ? const {EventShareAccessMode.oneTime} : const {},
    maxTtlSeconds: configured ? 3600 : 0,
    requiredMasks: configured
        ? const {EventShareMask.face, EventShareMask.licensePlate}
        : const {},
    requiredMetadata: configured
        ? const {
            EventShareMetadata.deviceSerial,
            EventShareMetadata.gps,
            EventShareMetadata.cameraName,
            EventShareMetadata.networkAddress,
          }
        : const {},
    fullFrameOnly: configured,
  );

  @override
  Future<PrivateEventShareSetup> setup() async => PrivateEventShareSetup(
    currentUserId: admin,
    members: const [
      PrivateEventShareMember(id: admin, username: 'admin', canGrant: true),
      PrivateEventShareMember(
        id: recipient,
        username: 'reviewer',
        canGrant: false,
      ),
    ],
    policy: _policy,
  );

  @override
  Future<PrivateEventShareSetup> configurePolicy(
    PrivateEventSharePolicyDraft draft,
  ) async {
    expect(draft.recipientId, recipient);
    expect(draft.purpose, 'incident review');
    configured = true;
    return setup();
  }

  @override
  Future<PrivateEventShareConsent> acceptConsent(
    PrivateEventSharePolicyDraft draft,
  ) async {
    expect(configured, isTrue);
    consents++;
    return PrivateEventShareConsent(
      id: '33333333333333333333333333333333',
      revision: 1,
      recipientId: draft.recipientId,
      purpose: draft.purpose,
      accessMode: draft.accessMode,
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      masks: const {EventShareMask.face, EventShareMask.licensePlate},
      removedMetadata: const {
        EventShareMetadata.deviceSerial,
        EventShareMetadata.gps,
        EventShareMetadata.cameraName,
        EventShareMetadata.networkAddress,
      },
    );
  }

  @override
  Future<EventShareSnapshot> snapshot() async => EventShareSnapshot(
    revision: 1,
    shares: const [],
    audit: const [],
    auditTruncated: false,
  );

  @override
  Future<EventRedactionPreview> preview(EventShareDraft draft) async {
    previews++;
    return EventRedactionPreview(
      previewId: '4' * 32,
      sourceDigest: '5' * 64,
      outputDigest: '6' * 64,
      outputArtifactId: '4' * 32,
      pipelineId: '7' * 32,
      pipelineRevision: 1,
      proof: '8' * 64,
      masks: draft.masks,
      removedMetadata: draft.removedMetadata,
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
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

  testWidgets('whole-frame policy requires explicit consent before preview', (
    tester,
  ) async {
    final api = _SetupApi();
    final controller = PrivateEventShareController(
      api,
      commandIds: () => 'a' * 32,
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
    await _pump(tester, language: 'en', controller: controller);

    expect(
      find.byKey(const ValueKey('private-event-full-frame-explanation')),
      findsOneWidget,
    );
    expect(find.textContaining('does not detect'), findsOneWidget);
    await tester.tap(
      find.byKey(
        const ValueKey('private-event-recipient-${_SetupApi.recipient}'),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('private-event-purpose')),
      'incident review',
    );
    await tester.pump();
    expect(controller.state, EventShareState.ready);
    expect(controller.setupResult, isNotNull);
    expect(
      tester
          .widget<CupertinoTextField>(
            find.byKey(const ValueKey('private-event-purpose')),
          )
          .controller
          ?.text,
      'incident review',
    );
    expect(
      tester
          .widget<CupertinoButton>(
            find.byKey(
              const ValueKey('private-event-recipient-${_SetupApi.recipient}'),
            ),
          )
          .color,
      CupertinoColors.activeBlue,
    );
    final save = find.byKey(const ValueKey('private-event-save-policy'));
    await tester.ensureVisible(save);
    expect(tester.widget<CupertinoButton>(save).onPressed, isNotNull);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(api.configured, isTrue);

    final preview = find.byKey(const ValueKey('private-event-create-preview'));
    await tester.ensureVisible(preview);
    expect(tester.widget<CupertinoButton>(preview).onPressed, isNull);
    expect(api.previews, 0);

    final consentSwitch = find.byKey(
      const ValueKey('private-event-consent-switch'),
    );
    tester.widget<CupertinoSwitch>(consentSwitch).onChanged!(true);
    await tester.pump();
    final record = find.byKey(const ValueKey('private-event-record-consent'));
    tester.widget<CupertinoButton>(record).onPressed!.call();
    await tester.pumpAndSettle();
    expect(api.consents, 1);
    expect(
      find.byKey(const ValueKey('private-event-consent-recorded')),
      findsOneWidget,
    );

    tester.widget<CupertinoButton>(preview).onPressed!.call();
    await tester.pumpAndSettle();
    expect(api.previews, 1);
    expect(tester.takeException(), isNull);
  });
}
