import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/backup/data/backup_repository.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/wellbeing/data/wellbeing_disclosure_policy.dart';
import 'package:larenor/features/wellbeing/data/wellbeing_store.dart';
import 'package:larenor/features/wellbeing/domain/wellbeing_models.dart';
import 'package:larenor/features/wellbeing/providers/wellbeing_privacy_providers.dart';
import 'package:larenor/features/wellbeing/providers/wellbeing_providers.dart';

import '../wellbeing/wellbeing_data_test.dart' show binding;
import 'backup_test_storage.dart';

const _layout = {
  'rooms': [],
  'tiles': [],
  'favoriteEntityIds': ['sensor.scale'],
  'hiddenEntityIds': [],
};

Future<AsyncValue<Map<String, HaEntity>>> _public(
  MemoryBackupStorage storage,
) async {
  FlutterSecureStorage.setMockInitialValues(storage.secrets);
  final container = ProviderContainer(
    overrides: [
      entitiesProvider.overrideWithBuild(
        (ref, notifier) async => {
          'sensor.scale': const HaEntity(
            entityId: 'sensor.scale',
            state: '70.2',
          ),
          'light.kitchen': const HaEntity(
            entityId: 'light.kitchen',
            state: 'on',
          ),
        },
      ),
    ],
  );
  final subscription = container.listen(publicHaEntitiesProvider, (_, _) {});
  await container.read(wellbeingSettingsProvider.future);
  await container.read(wellbeingDisclosureProvider.future);
  await container.read(entitiesProvider.future);
  await container.pump();
  final result = container.read(publicHaEntitiesProvider);
  subscription.close();
  container.dispose();
  return result;
}

void main() {
  test('fresh restore hides a previously saved private sensor without exporting its person', () async {
    final source = MemoryBackupStorage(
      preferences: {'dashboard_layout': jsonEncode(_layout)},
      secrets: {
        WellbeingStore.storageKey: jsonEncode(
          WellbeingStore.encode(
            WellbeingSettings(
              enabled: true,
              profileLabel: 'Private human fixture',
              bindings: [binding()],
            ),
          ),
        ),
        'settings_pin': '123456',
      },
    );
    final snapshot = await BackupRepository(storage: source)
        .capture(const BackupSelection());
    final json = snapshot.toJson();
    expect(json['version'], 2);
    expect(jsonEncode(json), isNot(contains('Private human fixture')));
    expect(jsonEncode(json), isNot(contains('Synthetic person')));
    expect(jsonEncode(json), isNot(contains('123456')));
    expect((json['groups'] as Map)['privacy']['entityIds'], ['sensor.scale']);
    final target = MemoryBackupStorage();
    final repo = BackupRepository(storage: target);
    expect((await repo.preview(snapshot)).protectedEntityCount, 1);
    await repo.restore(snapshot, const BackupSelection());
    expect(target.secrets.containsKey(WellbeingStore.storageKey), false);
    expect(target.secrets.containsKey('settings_pin'), false);
    final public = await _public(target);
    expect(public.requireValue.keys, ['light.kitchen']);
    expect(
      jsonEncode(target.preferences['dashboard_layout']),
      contains('sensor.scale'),
    );
  });

  test(
    'restore merges protections even when existing configuration is replaced',
    () async {
      final incoming = BackupSnapshot.fromJson({
        'version': 2,
        'createdAt': '2026-09-05T00:00:00Z',
        'groups': {
          'dashboard': _layout,
          'privacy': WellbeingDisclosurePolicy(entityIds: {'sensor.scale'})
              .toJson(),
        },
      });
      final target = MemoryBackupStorage(
        secrets: {
          WellbeingDisclosureStore.storageKey: jsonEncode(
            WellbeingDisclosurePolicy(
              entityIds: {'sensor.other'},
              reviewRequired: true,
            ).toJson(),
          ),
        },
      );
      await BackupRepository(storage: target).restore(
        incoming,
        const BackupSelection(),
        conflictPolicy: BackupConflictPolicy.replaceSelected,
      );
      final merged = WellbeingDisclosurePolicy.decode(
        target.secrets[WellbeingDisclosureStore.storageKey],
      );
      expect(merged.entityIds, {'sensor.other', 'sensor.scale'});
      expect(merged.reviewRequired, true);
    },
  );

  test('legacy restored HA inventory remains hidden until an explicit privacy review', () async {
    final incoming = BackupSnapshot.fromJson({
      'version': 1,
      'createdAt': '2026-09-05T00:00:00Z',
      'groups': {'dashboard': _layout},
    });
    final target = MemoryBackupStorage();
    final repo = BackupRepository(storage: target);
    expect((await repo.preview(incoming)).requiresPrivacyReview, true);
    await repo.restore(incoming, const BackupSelection());
    expect((await _public(target)).hasError, true);
    final policy = WellbeingDisclosurePolicy.decode(
      target.secrets[WellbeingDisclosureStore.storageKey],
    );
    expect(policy.reviewRequired, true);
  });

  for (final key in [
    WellbeingStore.storageKey,
    WellbeingDisclosureStore.storageKey,
  ]) {
    test(
      'corrupt $key prevents a backup that would lose its privacy policy',
      () async {
        final source = MemoryBackupStorage(
          secrets: {key: 'not-json-private-fixture'},
        );
        await expectLater(
          BackupRepository(storage: source).capture(const BackupSelection()),
          throwsA(isA<BackupException>()),
        );
        expect(source.writes, isEmpty);
      },
    );
  }

  test('missing or invalid v2 privacy policy is rejected before any restore writes', () async {
    for (final value in [
      null,
      {
        'version': 1,
        'entityIds': ['switch.private'],
        'reviewRequired': false,
      },
      {
        'version': 1,
        'entityIds': ['sensor.x', 'sensor.x'],
        'reviewRequired': false,
      },
    ]) {
      expect(
        () => BackupSnapshot.fromJson({
          'version': 2,
          'createdAt': '2026-09-05T00:00:00Z',
          'groups': {'dashboard': _layout, 'privacy': value},
        }),
        throwsA(isA<BackupValidationException>()),
      );
    }
  });
}
