import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/configuration_writes.dart';
import 'package:larenor/features/backup/data/backup_repository.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';
import 'package:larenor/features/intercom/data/door_station_store.dart';
import 'package:larenor/features/intercom/domain/door_station.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../backup/backup_test_storage.dart';

const fixtureStation = DoorStation(
  id: 'front',
  name: 'Bina kapısı',
  serverUrl: 'http://ha.test',
  cameraEntityId: 'camera.front',
  chimeEntityId: 'binary_sensor.chime',
  callActiveEntityId: 'binary_sensor.call',
  doorContactEntityId: 'binary_sensor.front',
  unlockEntityId: 'button.release',
  unlockEnabled: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('schema defaults disable release and require an active call', () {
    final minimal = DoorStation.fromJson({
      'id': 'front',
      'name': 'Door',
      'serverUrl': 'https://ha.test/proxy',
    });
    expect(minimal.unlockEnabled, isFalse);
    expect(minimal.requiresActiveCall, isTrue);
    final decoded = DoorStation.decodeStored(
      DoorStation.encodeStored([fixtureStation]),
    );
    expect(decoded, [fixtureStation]);
    expect(decoded.single.hashCode, fixtureStation.hashCode);
    expect(() => decoded.clear(), throwsUnsupportedError);
  });

  final invalid = <String, Map<String, dynamic>>{
    'persistent switch release': {'unlockEntityId': 'switch.relay'},
    'input button release': {'unlockEntityId': 'input_button.release'},
    'entity target injection': {
      'unlockEntityId': 'button.release,button.other',
    },
    'camera domain confusion': {'cameraEntityId': 'sensor.camera'},
    'call domain confusion': {'callActiveEntityId': 'switch.call'},
    'missing commissioned call': {'callActiveEntityId': null},
    'missing commissioned release': {'unlockEntityId': null},
    'explicit null boolean': {'unlockEnabled': null},
    'string boolean': {'requiresActiveCall': 'false'},
    'extra secret field': {'token': 'must-never-appear'},
    'user info URL': {'serverUrl': 'https://user:must-never-appear@ha.test'},
    'query URL': {'serverUrl': 'https://ha.test?token=must-never-appear'},
    'URL traversal': {'serverUrl': 'https://ha.test/%2e%2e/private'},
    'URL port range': {'serverUrl': 'https://ha.test:65536'},
    'URL backslash': {'serverUrl': r'https://ha.test\private'},
    'control characters': {'name': 'Door\u007f'},
  };
  for (final entry in invalid.entries) {
    test('reject ${entry.key} without echoing configuration', () {
      try {
        DoorStation.decodeStored(
          jsonEncode([
            {...fixtureStation.toJson(), ...entry.value},
          ]),
        );
        fail('Invalid station was accepted.');
      } on FormatException catch (error) {
        expect(error.toString(), isNot(contains('must-never-appear')));
      }
    });
  }

  test(
    'reject duplicate IDs, non-object entries, excessive count and bytes',
    () {
      for (final value in [
        [fixtureStation.toJson(), fixtureStation.toJson()],
        ['invalid'],
        List.generate(17, (i) => {...fixtureStation.toJson(), 'id': 's$i'}),
      ]) {
        expect(() => DoorStation.decodeList(value), throwsFormatException);
      }
      expect(
        () => DoorStation.decodeStored(' ' * (64 * 1024 + 1)),
        throwsFormatException,
      );
      final large = List.generate(
        16,
        (i) => DoorStation.fromJson({
          ...fixtureStation.toJson(),
          'id': 's$i',
          'serverUrl': 'https://ha.test/${'ü' * 2000}',
        }),
      );
      expect(() => DoorStation.encodeStored(large), throwsFormatException);
    },
  );

  test(
    'store writes an immutable queued snapshot and serializes reads',
    () async {
      final gate = Completer<void>();
      final held = ConfigurationWrites.run(() => gate.future);
      final mutable = [fixtureStation];
      final save = DoorStationStore().save(mutable);
      mutable.clear();
      var readCompleted = false;
      final read = DoorStationStore().read().then((value) {
        readCompleted = true;
        return value;
      });
      await Future<void>.delayed(Duration.zero);
      expect(readCompleted, isFalse);
      gate.complete();
      await held;
      await save;
      expect(await read, [fixtureStation]);
    },
  );

  test(
    'queued save rejects a changed account without overwriting preferences',
    () async {
      await DoorStationStore().save([fixtureStation]);
      final gate = Completer<void>();
      final held = ConfigurationWrites.run(() => gate.future);
      var current = true;
      final save = DoorStationStore().save([], isCurrent: () => current);
      final rejected = expectLater(save, throwsStateError);
      current = false;
      gate.complete();
      await held;
      await rejected;
      expect(await DoorStationStore().read(), [fixtureStation]);
    },
  );

  test(
    'concurrent upserts and removal preserve unrelated station mappings',
    () async {
      final second = DoorStation.fromJson({
        ...fixtureStation.toJson(),
        'id': 'second',
      });
      final third = DoorStation.fromJson({
        ...fixtureStation.toJson(),
        'id': 'third',
      });
      final store = DoorStationStore();
      await Future.wait([store.upsert(fixtureStation), store.upsert(second)]);
      expect((await store.read()).map((station) => station.id), [
        'front',
        'second',
      ]);
      await Future.wait([store.remove('front'), store.upsert(third)]);
      expect((await store.read()).map((station) => station.id), [
        'second',
        'third',
      ]);
      await expectLater(
        store.upsert(fixtureStation, isCurrent: () => false),
        throwsStateError,
      );
      expect((await store.read()).map((station) => station.id), [
        'second',
        'third',
      ]);
    },
  );

  test('wrong preference type and oversized payload fail closed', () async {
    SharedPreferences.setMockInitialValues({DoorStation.storageKey: true});
    await expectLater(DoorStationStore().read(), throwsFormatException);
    SharedPreferences.setMockInitialValues({
      DoorStation.storageKey: ' ' * (64 * 1024 + 1),
    });
    await expectLater(DoorStationStore().read(), throwsFormatException);
  });

  test(
    'backup keeps mappings but restore clears physical control approval',
    () async {
      final encoded = DoorStation.encodeStored([fixtureStation]);
      final source = MemoryBackupStorage(
        preferences: {DoorStation.storageKey: encoded},
      );
      final captured = await BackupRepository(storage: source)
          .capture(const BackupSelection());
      final capturedValue =
          (captured.toJson()['groups']
              as Map)['settings'][DoorStation.storageKey];
      expect(capturedValue, encoded);
      final destination = MemoryBackupStorage();
      await BackupRepository(storage: destination)
          .restore(captured, const BackupSelection());
      final restored = DoorStation.decodeStored(
        destination.preferences[DoorStation.storageKey],
      ).single;
      expect(restored.unlockEnabled, isFalse);
      expect(restored.requiresActiveCall, isTrue);
      expect(restored.unlockEntityId, fixtureStation.unlockEntityId);
      expect(restored.cameraEntityId, fixtureStation.cameraEntityId);
      expect(restored.serverUrl, fixtureStation.serverUrl);
      expect(source.preferences[DoorStation.storageKey], encoded);
    },
  );

  test(
    'keepExisting preserves commissioned local mapping; rollback restores it',
    () async {
      final original = DoorStation.encodeStored([fixtureStation]);
      final snapshot = BackupSnapshot.fromJson({
        'version': 1,
        'createdAt': '2026-09-05T00:00:00Z',
        'groups': {
          'settings': {DoorStation.storageKey: original, 'appearance': 'dark'},
        },
      });
      final kept = MemoryBackupStorage(
        preferences: {DoorStation.storageKey: original},
      );
      await BackupRepository(storage: kept)
          .restore(snapshot, const BackupSelection());
      expect(kept.preferences[DoorStation.storageKey], original);
      final failed = MemoryBackupStorage(
        preferences: {DoorStation.storageKey: original},
      );
      failed.failWrites.add(3); // journal, station write, appearance failure
      await expectLater(
        BackupRepository(storage: failed).restore(
          snapshot,
          const BackupSelection(),
          conflictPolicy: BackupConflictPolicy.replaceSelected,
        ),
        throwsA(isA<BackupRestoreException>()),
      );
      expect(failed.preferences[DoorStation.storageKey], original);
    },
  );

  test(
    'backup rejects encoded station schema violations even in unselected group',
    () async {
      for (final value in [
        [
          fixtureStation.toJson(),
        ], // storage is a JSON string, not an object list
        jsonEncode([
          {...fixtureStation.toJson(), 'unlockEntityId': 'switch.relay'},
        ]),
        jsonEncode([
          {...fixtureStation.toJson(), 'extra': 'secret'},
        ]),
        'not-json',
        ' ' * (64 * 1024 + 1),
      ]) {
        expect(
          () => BackupSnapshot.fromJson({
            'version': 1,
            'createdAt': '2026-09-05T00:00:00Z',
            'groups': {
              'settings': {DoorStation.storageKey: value},
              'dashboard': {},
            },
          }),
          throwsA(isA<BackupValidationException>()),
        );
      }
    },
  );
}
