import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/camera_search/data/camera_search_api.dart';
import 'package:larenor/features/camera_search/domain/camera_search_models.dart';
import 'package:larenor/features/private_event_sharing/data/private_event_share_account_api.dart';
import 'package:larenor/features/private_event_sharing/domain/private_event_share_models.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

class _Store implements ServerSessionPersistence {
  @override
  Future<ServerSession?> read() async => null;
  @override
  Future<void> write(ServerSession? value) async {}
}

void main() {
  final url = Platform.environment['LARENOR_F42_CORE_URL'];
  setUpAll(() => HttpOverrides.global = null);
  test(
    'actual Client configures consent and shares a real Frigate clip transformed by FFmpeg',
    () async {
      final account = ServerAccountController(store: _Store());
      addTearDown(account.dispose);
      await account.signIn(
        baseUrl: url!,
        username: 'admin',
        password: 'Synthetic new password 2026',
        deviceName: 'Private event gate',
      );
      expect(account.failure, isNull);
      await account.withSession((transport, session) async {
        final searchApi = CameraSearchApi(
          transport,
          session,
          isCurrent: () => true,
        );
        addTearDown(searchApi.retire);
        final context = await searchApi.loadContext();
        final page = await searchApi.search(
          query: 'red parcel',
          filter: CameraSearchFilter(
            expectedIndexRevision: context.indexRevision,
            start: DateTime.fromMillisecondsSinceEpoch(
              1788609500000,
              isUtc: true,
            ),
            end: DateTime.fromMillisecondsSinceEpoch(
              1788609700000,
              isUtc: true,
            ),
            cameraIds: context.cameraIds,
          ),
        );
        final evidence = page.results.first.evidence;
        final api = PrivateEventShareAccountApi(
          transport,
          session,
          cameraId: evidence.cameraId,
          eventId: evidence.eventId,
          isCurrent: () => true,
        );
        addTearDown(api.retire);
        final draft = PrivateEventSharePolicyDraft(
          recipientId: session.user.id,
          purpose: 'Door incident',
          ttlSeconds: 3600,
          accessMode: EventShareAccessMode.oneTime,
        );
        final initial = await api.setup();
        expect(initial.policy.configured, isFalse);
        final configured = await api.configurePolicy(draft);
        expect(configured.policy.fullFrameOnly, isTrue);
        expect(configured.policy.recipientIds, [session.user.id]);
        final consent = await api.acceptConsent(draft);
        final shareDraft = consent.draftFor(draft)!;
        final preview = await api.preview(shareDraft);
        expect(preview.sourceDigest, isNot(preview.outputDigest));
        expect(preview.masks, {
          EventShareMask.face,
          EventShareMask.licensePlate,
        });
        final snapshot = await api.snapshot();
        final created = await api.create(
          expectedRevision: snapshot.revision,
          commandId: 'd' * 32,
          draft: shareDraft,
          preview: preview,
        );
        final download = await api.download(
          accessToken: created.accessToken,
          accessId: 'e' * 32,
        );
        expect(download.bytes.length, greaterThan(1000));
        expect(String.fromCharCodes(download.bytes.sublist(4, 8)), 'ftyp');
        download.bytes.fillRange(0, download.bytes.length, 0);
      });
    },
    skip: url == null ? 'Requires explicit isolated normal Core runner' : false,
  );
}
