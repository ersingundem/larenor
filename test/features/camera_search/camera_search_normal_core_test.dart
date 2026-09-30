import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/camera_search/data/camera_search_api.dart';
import 'package:larenor/features/camera_search/domain/camera_search_models.dart';
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
  final url = Platform.environment['LARENOR_SEARCH_CORE_URL'];
  setUpAll(() => HttpOverrides.global = null);
  test(
    'actual Client → normal Core → Frigate search/setup/feedback',
    () async {
      final account = ServerAccountController(store: _Store());
      addTearDown(account.dispose);
      await account.signIn(
        baseUrl: url!,
        username: 'admin',
        password: 'Synthetic new password 2026',
        deviceName: 'Search gate',
      );
      expect(account.failure, isNull);
      await account.withSession((transport, session) async {
        final api = CameraSearchApi(transport, session, isCurrent: () => true);
        addTearDown(api.retire);
        final source = await api.sources();
        expect(source.cameras.length, 2);
        expect(source.services.length, 1);
        final configured = await api.configureSources(
          revision: source.revision,
          service: source.services.single,
          cameras: source.cameras.map((c) => c.id).toList(),
        );
        expect(configured.revision, source.revision + 1);
        final context = await api.loadContext();
        final filter = CameraSearchFilter(
          expectedIndexRevision: context.indexRevision,
          start: DateTime.fromMillisecondsSinceEpoch(
            1788609500000,
            isUtc: true,
          ),
          end: DateTime.fromMillisecondsSinceEpoch(1788609700000, isUtc: true),
          cameraIds: context.cameraIds,
        );
        final page = await api.search(query: 'red parcel', filter: filter);
        expect(page.mode, CameraSearchMode.semanticAssisted);
        expect(page.results.length, 2);
        final clip = await api.clip(page.results.first.evidence);
        expect(clip.length, greaterThan(1000));
        expect(String.fromCharCodes(clip.sublist(4, 8)), 'ftyp');
        clip.fillRange(0, clip.length, 0);
        await api.reportIncorrect(
          query: 'red parcel',
          expectedIndexRevision: context.indexRevision,
          evidence: page.results.first.evidence,
          reason: CameraSearchFeedbackReason.wrongSummary,
        );
        final corrected = await api.search(query: 'red parcel', filter: filter);
        expect(corrected.results.length, 1);
        expect(
          corrected.results.single.evidence.eventId,
          isNot(page.results.first.evidence.eventId),
        );
      });
    },
    skip: url == null ? 'Requires explicit isolated normal Core runner' : false,
  );
}
