import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/music_retained/domain/server_music_retained_models.dart';

void main() {
  test(
    'retained overview binds exact installation service and provider revisions',
    () {
      final overview = ServerMusicRetainedOverview.fromJson(retainedJson());
      expect(overview.state, 'ready');
      final record = overview.installations.single;
      expect(record.installationId, 'a' * 32);
      expect(record.installationRevision, 4);
      expect(record.bootstrap!.homeAssistant.serviceRevision, 8);
      expect(record.providers.single.revision, 3);
      expect(overview.installAvailable, isFalse);
    },
  );

  test(
    'retained overview rejects partial, duplicate and secret-bearing shapes',
    () {
      final original = retainedJson();
      for (final changed in [
        {...original, 'token': 'secret'},
        {
          ...original,
          'installations': [
            ...original['installations'] as List,
            ...original['installations'] as List,
          ],
        },
        {...original, 'state': 'partial'},
      ]) {
        expect(
          () => ServerMusicRetainedOverview.fromJson(changed),
          throwsA(isA<Exception>()),
        );
      }
    },
  );
}

Map<String, dynamic> retainedJson() => {
  'schemaVersion': 1,
  'state': 'ready',
  'installAvailable': false,
  'installations': [
    {
      'installationId': 'a' * 32,
      'installationRevision': 4,
      'installationState': 'container_started',
      'state': 'ready',
      'errorCode': null,
      'bootstrapReceipt': {
        'revision': 2,
        'state': 'ready',
        'serverVersion': '2.10.2',
        'schemaVersion': 27,
        'homeAssistant': {'serviceId': 'b' * 32, 'serviceRevision': 8},
        'jellyfin': {'serviceId': 'c' * 32, 'serviceRevision': 5},
      },
      'providers': [
        {
          'id': 'd' * 32,
          'providerDomain': 'spotify',
          'revision': 3,
          'state': 'ready',
          'updatedAt': '2026-09-10T10:00:00.000Z',
        },
      ],
    },
  ],
};
