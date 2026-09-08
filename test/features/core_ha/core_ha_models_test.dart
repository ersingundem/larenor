import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/core_ha/domain/core_ha_models.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/server/domain/server_models.dart';

// Synthetic boundaries until the Server's authenticated HTTP export is frozen.
Map<String, dynamic> scopeJson() => {
  'schemaVersion': 1,
  'coreId': '1' * 32,
  'homeId': '2' * 32,
};
Map<String, dynamic> refJson() => {
  ...scopeJson(),
  'kind': 'resource',
  'id': '3' * 32,
};
Map<String, dynamic> resourceJson() => {
  'ref': refJson(),
  'label': 'Reading lamp',
  'order': 1,
  'revision': 1,
  'aclRevision': 1,
  'permissions': {'read': true, 'write': true},
};
HomeResourceRecord target() => HomeResourceRecord.fromJson(
  resourceJson(),
  expectedContext: ServerContext.fromJson(scopeJson()),
);
Map<String, dynamic> projectionJson() => {
  'kind': 'switch',
  'state': 'off',
  'commandAvailable': false,
};
Map<String, dynamic> bindingJson() => {
  'schemaVersion': 1,
  'id': '4' * 32,
  'revision': 1,
  'ref': refJson(),
  'serviceId': '5' * 32,
  'serviceRevision': 1,
  'entityId': 'switch.reading_lamp',
};
Map<String, dynamic> snapshotJson() => {
  'schemaVersion': 1,
  'ref': refJson(),
  'bindingId': '4' * 32,
  'bindingRevision': 1,
  'resourceRevision': 1,
  'aclRevision': 1,
  'serviceRevision': 1,
  'observedAt': '2026-09-08T00:00:00Z',
  'remainingTtlMs': 5000,
  'projection': projectionJson(),
};
Map<String, dynamic> previewJson() => {
  'id': '6' * 32,
  'expiresInMs': 60000,
  'binding': bindingJson(),
  'projection': projectionJson(),
};
Map<String, dynamic> copy(Map<String, dynamic> raw) =>
    jsonDecode(jsonEncode(raw)) as Map<String, dynamic>;
Matcher failure(String code) =>
    isA<LarenorServerException>().having((e) => e.code, 'static code', code);

void main() {
  test('closed switch read projection never provides a command', () {
    for (final state in CoreHaSwitchState.values) {
      final p = CoreHaProjection.fromJson({
        ...projectionJson(),
        'state': state.name,
      });
      expect(p.state, state);
      expect(p.commandAvailable, isFalse);
    }
    for (final invalid in [0, null]) {
      expect(
        () => CoreHaProjection.fromJson({
          ...projectionJson(),
          'commandAvailable': invalid,
        }),
        throwsA(failure('invalid_response')),
      );
    }
  });
  test('snapshot binds exact resource and bounded server freshness', () {
    final value = CoreHaSnapshot.fromJson(snapshotJson(), target: target());
    expect(value.bindingId, '4' * 32);
    expect(value.remainingTtlMs, 5000);
    expect(value.observedAt.isUtc, isTrue);
    expect(value.resourceRevision, 1);
    expect(value.toString(), 'CoreHaSnapshot');
    expect(
      CoreHaSnapshot.fromJson({
        ...snapshotJson(),
        'remainingTtlMs': 0,
      }, target: target()).remainingTtlMs,
      0,
    );
  });
  test('preview and binding retain immutable typed identity', () {
    final json = previewJson(),
        value = CoreHaPreview.fromJson(json, target: target());
    (json['binding'] as Map)['entityId'] = 'switch.changed';
    expect(value.binding.entityId, 'switch.reading_lamp');
    expect(
      value.binding.sameBinding(
        CoreHaBinding.fromJson(bindingJson(), target: target()),
      ),
      isTrue,
    );
    expect(value.expiresInMs, 60000);
    expect(value.toString(), 'CoreHaPreview');
  });
  for (final entry in <String, Object?>{
    'commandAvailable': true,
    'kind': 'light',
    'state': 'unknown',
    'extra': 'private',
  }.entries) {
    test('projection rejects ${entry.key}=${entry.value}', () {
      expect(
        () => CoreHaProjection.fromJson({
          ...projectionJson(),
          entry.key: entry.value,
        }),
        throwsA(failure('invalid_response')),
      );
    });
  }
  for (final entry in <String, Object?>{
    'schemaVersion': 2,
    'remainingTtlMs': 5001,
    'bindingRevision': 0,
    'aclRevision': true,
    'serviceRevision': 1.0,
    'bindingId': 'UPPER',
    'observedAt': '2026-09-08',
    'extra': 'private',
  }.entries) {
    test('snapshot rejects ${entry.key}', () {
      expect(
        () => CoreHaSnapshot.fromJson({
          ...snapshotJson(),
          entry.key: entry.value,
        }, target: target()),
        throwsA(failure('invalid_response')),
      );
    });
  }
  for (final entry in {
    'coreId': '7' * 32,
    'homeId': '8' * 32,
    'id': '9' * 32,
    'kind': 'room',
  }.entries) {
    test('foreign snapshot ${entry.key} is rejected', () {
      expect(
        () => CoreHaSnapshot.fromJson({
          ...snapshotJson(),
          'ref': {...refJson(), entry.key: entry.value},
        }, target: target()),
        throwsA(failure('invalid_response')),
      );
    });
  }
  test('binding and preview reject unknown fields and excessive lifetime', () {
    expect(
      () => CoreHaBinding.fromJson({
        ...bindingJson(),
        'url': 'private',
      }, target: target()),
      throwsA(failure('invalid_response')),
    );
    for (final ttl in [0, 60001]) {
      expect(
        () => CoreHaPreview.fromJson({
          ...previewJson(),
          'expiresInMs': ttl,
        }, target: target()),
        throwsA(failure('invalid_response')),
      );
    }
  });
  test('entity selector matches closed ASCII switch identifier', () {
    expect(coreHaEntityId('switch.${'x' * 121}'), isTrue);
    for (final text in [
      'light.lamp',
      'switch.',
      'switch.Lamp',
      ' switch.lamp',
      'switch.lamp\n',
      'switch.%2f',
      'switch.ışık',
      'switch.${'x' * 122}',
    ]) {
      expect(coreHaEntityId(text), isFalse, reason: text);
    }
  });
}
