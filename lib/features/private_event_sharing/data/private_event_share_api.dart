import '../domain/private_event_share_models.dart';

abstract interface class PrivateEventShareApi {
  Future<EventShareSnapshot> snapshot();

  Future<EventRedactionPreview> preview(EventShareDraft draft);

  Future<CreatedPrivateEventShare> create({
    required int expectedRevision,
    required String commandId,
    required EventShareDraft draft,
    required EventRedactionPreview preview,
  });

  Future<void> revoke({
    required int expectedRevision,
    required String commandId,
    required String shareId,
  });

  Future<EventShareDownload> download({
    required String accessToken,
    required String accessId,
  });
}

abstract interface class PrivateEventShareSetupApi {
  Future<PrivateEventShareSetup> setup();

  Future<PrivateEventShareSetup> configurePolicy(
    PrivateEventSharePolicyDraft draft,
  );

  Future<PrivateEventShareConsent> acceptConsent(
    PrivateEventSharePolicyDraft draft,
  );
}
