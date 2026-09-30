import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_client.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_config.dart';
import 'package:larenor/features/media/playback_quality/data/android_playback_capability_port.dart';
import 'package:larenor/features/media/playback_quality/data/core_playback_quality_controller.dart';
import 'package:larenor/features/media/playback_quality/data/core_playback_quality_request_adapter.dart';
import 'package:larenor/features/media/playback_quality/domain/core_playback_quality_advice.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

final class _Store implements ServerSessionPersistence {
  ServerSession? value;

  @override
  Future<ServerSession?> read() async => value;

  @override
  Future<void> write(ServerSession? session) async => value = session;
}

void main() {
  final coreUrl = Platform.environment['LARENOR_F26_CORE_URL'];
  setUpAll(() => HttpOverrides.global = null);

  test(
    'real Jellyfin negotiation reaches normal Core as reported advice',
    () async {
      final jellyfin = JellyfinClient(
        config: JellyfinConfig(
          baseUrl: Platform.environment['LARENOR_F26_JELLYFIN_URL']!,
          userId: 'f26-user',
          accessToken: 'f26-owned-token',
          deviceId: 'f26-client',
        ),
      );
      addTearDown(jellyfin.dispose);
      final source = await jellyfin.getPlaybackInfo(
        'movie-1',
        maxStreamingBitrate: 20000000,
      );
      expect(source.isTranscoding, isTrue);
      expect(source.mediaSourceId, 'main-source');
      expect(source.qualityEvidence, isNotNull);

      final platform = AndroidPlaybackCapabilitySnapshot.fromChannel({
        'schemaVersion': 1,
        'decoderMimeTypes': ['audio/eac3', 'video/hevc'],
        'decoderMimeTypesTruncated': false,
        'displayWidthPixels': 3840,
        'displayHeightPixels': 2160,
        'displayHdrTypes': ['hdr10'],
        'networkTransports': ['wifi'],
        'networkValidated': true,
        'networkMetered': false,
        'networkDownstreamKbps': 20000,
      });
      final request = CorePlaybackQualityRequestAdapter.localAndroid(
        source,
        platform,
      );
      expect(request.media.state, CorePlaybackEvidenceState.reported);
      expect(request.receiver.state, CorePlaybackEvidenceState.reported);
      expect(request.network.state, CorePlaybackEvidenceState.reported);

      final account = ServerAccountController(store: _Store());
      addTearDown(account.dispose);
      await account.signIn(
        baseUrl: coreUrl!,
        username: 'admin',
        password: 'Synthetic new password 2026',
        deviceName: 'F26 acceptance',
      );
      expect(account.failure, isNull);

      final controller = CorePlaybackQualityController(
        account,
        requestId: () => '26262626262626262626262626262626',
      );
      addTearDown(controller.dispose);
      var current = true;
      await controller.advise(request, current: () => current);
      expect(controller.failure, isNull);
      final advice = controller.advice!;
      expect(advice.method, CorePlaybackMethod.transcode);
      expect(advice.confidence, CorePlaybackEvidenceState.reported);
      expect(advice.codecEvidence, CorePlaybackEvidenceState.reported);
      expect(advice.hdrEvidence, CorePlaybackEvidenceState.reported);
      expect(advice.gaps, isEmpty);
      expect(advice.reasons, [
        'server_transcode',
        'video_codec_mismatch',
        'bitrate_limit',
      ]);
      expect(advice.recommendations.map((value) => value.code), [
        CorePlaybackRecommendationCode.lowerBitrate,
        CorePlaybackRecommendationCode.inspectReceiver,
      ]);
      expect(advice.recommendations.first.maxBitrateBps, 14000000);

      current = false;
      controller.retire();
      await controller.advise(request, current: () => current);
      expect(controller.advice, isNull);
    },
    skip: coreUrl == null
        ? 'Run with server/tests/support/f26_flutter_acceptance.py'
        : false,
  );
}
