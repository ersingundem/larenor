import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/home_people/domain/home_person_models.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/server/domain/server_models.dart';

Map<String, dynamic> fixture() =>
    jsonDecode(File('contracts/home-people.v1.json').readAsStringSync())
        as Map<String, dynamic>;
Map<String, dynamic> copy(Object value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
Matcher failure(String code) =>
    isA<LarenorServerException>().having((e) => e.code, 'safe code', code);

void main() {
  final f = fixture();
  final context = ServerContext.fromJson(f['context']);
  final person = f['createPerson']['response']['person'];
  HomePersonRecord parse(Object? raw) =>
      HomePersonRecord.fromJson(raw, expectedContext: context);

  test(
    'actual person and Unicode contracts remain separate from rooms/resources',
    () {
      final value = parse(person);
      expect(value.id, '1' * 32);
      expect(value.context, context);
      expect(value.label, 'Deniz Öztürk');
      expect(value.order, 7);
      expect(value.revision, 1);
      expect(value.aclRevision, 1);
      expect(value.canWrite, isTrue);
      expect(value.toString(), 'HomePersonRecord');
      expect(
        parse(f['createUnicode']['response']['person']).label.runes.length,
        80,
      );
      expect(
        () => HomeResourceRecord.fromJson(person, expectedContext: context),
        throwsA(failure('invalid_response')),
      );
    },
  );
  final mutations = <String, void Function(Map<String, dynamic>)>{
    'unknown field': (v) => v['credential'] = 'never-reflect',
    'missing field': (v) => v.remove('order'),
    'unknown ref': (v) => v['ref']['userId'] = 'e' * 32,
    'room kind': (v) => v['ref']['kind'] = 'room',
    'resource kind': (v) => v['ref']['kind'] = 'resource',
    'bool schema': (v) => v['ref']['schemaVersion'] = true,
    'float schema': (v) => v['ref']['schemaVersion'] = 1.0,
    'wrong Core': (v) => v['ref']['coreId'] = 'c' * 32,
    'wrong home': (v) => v['ref']['homeId'] = 'd' * 32,
    'bad ID': (v) => v['ref']['id'] = 'F' * 32,
    'long ID': (v) => v['ref']['id'] = '1' * 33,
    'zero revision': (v) => v['revision'] = 0,
    'float revision': (v) => v['revision'] = 1.0,
    'bool ACL revision': (v) => v['aclRevision'] = true,
    'bad order': (v) => v['order'] = 10001,
    'float order': (v) => v['order'] = 1.0,
    'empty label': (v) => v['label'] = ' ',
    'oversized Unicode': (v) => v['label'] = '🌿' * 81,
    'control label': (v) => v['label'] = 'private\n',
    'surrogate label': (v) => v['label'] = '\ud800',
    'unreadable record': (v) => v['permissions']['read'] = false,
    'unknown permission': (v) => v['permissions']['execute'] = true,
    'wrong permission type': (v) => v['permissions']['write'] = 1,
  };
  for (final change in mutations.entries) {
    test('person parser rejects ${change.key}', () {
      final value = copy(person);
      change.value(value);
      expect(() => parse(value), throwsA(failure('invalid_response')));
    });
  }
  test('copied parsed metadata stays immutable and uses Python whitespace semantics', () {
    final raw = copy(person);
    raw['label'] = '\ufeff';
    final value = parse(raw);
    raw['label'] = 'mutated';
    raw['ref']['id'] = '5' * 32;
    expect(value.label, '\ufeff');
    expect(value.id, '1' * 32);
    for (final label in ['\ufeff', '\u0080', '\u202e', '🌿' * 80]) {
      expect(HomePersonMetadata(label: label, order: 10000).label, label);
    }
    final metadata = HomePersonMetadata(label: '  Deniz\u3000', order: 0);
    metadata.toJson()['label'] = 'changed';
    expect(metadata.label, 'Deniz');
    expect(metadata.toString(), 'HomePersonMetadata');
  });
  for (final invalid in ['', ' ', 'x' * 81, '\n', '\udfff']) {
    test('request metadata rejects invalid ${invalid.codeUnits}', () {
      expect(
        () => HomePersonMetadata(label: invalid, order: 0),
        throwsA(failure('invalid_request')),
      );
    });
  }
  test(
    'actual pages bind exact snapshot, cursor and Core/home without aliasing',
    () {
      final first = HomePeoplePage.fromJson(
        f['firstPage']['response'],
        expectedContext: context,
        limit: 1,
      );
      final second = HomePeoplePage.fromJson(
        f['secondPage']['response'],
        expectedContext: context,
        limit: 1,
        after: first.nextAfter,
        expectedSnapshot: first.snapshot,
      );
      expect(first.entries.single.id, '1' * 32);
      expect(second.entries.single.id, '2' * 32);
      expect(first.snapshot, second.snapshot);
      expect(second.nextAfter, isNull);
      expect(() => first.entries.clear(), throwsUnsupportedError);
      expect(HomePeoplePage.maximumRecords, 128);
      expect(first.toString(), 'HomePeoplePage');
      expect(
        () => HomePeoplePage.fromJson(
          f['otherContextList']['response'],
          expectedContext: context,
        ),
        throwsA(failure('invalid_response')),
      );
    },
  );
  final pages = <String, void Function(Map<String, dynamic>)>{
    'unknown': (v) => v['totalHidden'] = 1,
    'wrong scope': (v) => v['scope']['homeId'] = 'd' * 32,
    'wrong snapshot': (v) => v['snapshot'] = 'bad',
    'duplicate': (v) => v['entries'] = [v['entries'][0], v['entries'][0]],
    'reverse order': (v) =>
        v['entries'] = (v['entries'] as List).reversed.toList(),
    'unknown cursor': (v) => v['nextAfter'] = '9' * 32,
    'empty with cursor': (v) {
      v['entries'] = [];
      v['nextAfter'] = '1' * 32;
    },
    'oversized': (v) => v['entries'] = List.filled(101, v['entries'][0]),
  };
  for (final change in pages.entries) {
    test('list rejects ${change.key}', () {
      final value = copy(f['adminList']['response']);
      change.value(value);
      expect(
        () => HomePeoplePage.fromJson(value, expectedContext: context),
        throwsA(failure('invalid_response')),
      );
    });
  }
  test('page enforces requested limit, previous ID and expected snapshot', () {
    final raw = f['adminList']['response'];
    for (final limit in [0, 1, 101]) {
      expect(
        () => HomePeoplePage.fromJson(
          raw,
          expectedContext: context,
          limit: limit,
        ),
        throwsA(failure('invalid_response')),
      );
    }
    expect(
      () => HomePeoplePage.fromJson(
        raw,
        expectedContext: context,
        after: '1' * 32,
      ),
      throwsA(failure('invalid_response')),
    );
    expect(
      () => HomePeoplePage.fromJson(
        raw,
        expectedContext: context,
        after: '1' * 32,
        expectedSnapshot: raw['snapshot'] as String,
      ),
      throwsA(failure('invalid_response')),
    );
    expect(
      () => HomePeoplePage.fromJson(
        raw,
        expectedContext: context,
        expectedSnapshot: '0' * 64,
      ),
      throwsA(failure('invalid_response')),
    );
  });
  test(
    'actual grants no-op, read-write and revoke have exact ACL revisions',
    () {
      var grants = HomePersonGrants.fromJson(
        f['emptyGrants']['response'],
        target: parse(person),
      );
      final subject = f['subjectId'] as String;
      expect(grants.permissionFor(subject), HomePersonPermission.none);
      for (final (name, permission) in [
        ('grantRead', HomePersonPermission.readOnly),
        ('grantWrite', HomePersonPermission.readWrite),
        ('grantNoop', HomePersonPermission.readWrite),
        ('revoke', HomePersonPermission.none),
      ]) {
        grants = grants.withUpdatedGrant(
          f[name]['response'],
          subjectId: subject,
          permission: permission,
        );
      }
      expect(grants.aclRevision, 4);
      expect(grants.grants, isEmpty);
      expect(
        () => grants.grants[subject] = HomePersonPermission.readWrite,
        throwsUnsupportedError,
      );
      expect(grants.toString(), 'HomePersonGrants');
    },
  );
  final grantChanges = <String, void Function(Map<String, dynamic>)>{
    'unknown': (v) => v['private'] = 'not reflected',
    'duplicate subjects': (v) => v['grants'] = [v['grants'][0], v['grants'][0]],
    'too many': (v) => v['grants'] = List.filled(129, v['grants'][0]),
    'wrong target': (v) => v['grants'][0]['target']['id'] = '9' * 32,
    'wrong kind': (v) => v['grants'][0]['target']['kind'] = 'room',
    'mixed revision': (v) => v['grants'][0]['aclRevision'] = 1,
    'no-read entry': (v) => v['grants'][0]['permissions']['read'] = false,
    'bool revision': (v) => v['aclRevision'] = true,
    'invalid write without read': (v) {
      v['grants'][0]['permissions'] = {'read': false, 'write': true};
    },
    'nonbool grant': (v) => v['grants'][0]['permissions']['write'] = 1,
  };
  for (final change in grantChanges.entries) {
    test('grants reject ${change.key}', () {
      final raw = copy(f['grantsAfterRead']['response']);
      change.value(raw);
      expect(
        () => HomePersonGrants.fromJson(raw, target: parse(person)),
        throwsA(failure('invalid_response')),
      );
    });
  }
  test('grant acknowledgements require exact subject, permission and successor revision', () {
    final before = HomePersonGrants.fromJson(
      f['emptyGrants']['response'],
      target: parse(person),
    );
    final subject = f['subjectId'] as String;
    for (final changed in ['subject', 'revision', 'permission', 'unknown']) {
      final ack = copy(f['grantRead']['response']);
      if (changed == 'subject') ack['grant']['subjectId'] = '9' * 32;
      if (changed == 'revision') ack['grant']['aclRevision'] = 3;
      if (changed == 'permission') ack['grant']['permissions']['write'] = true;
      if (changed == 'unknown') ack['grant']['private'] = 'never-reflect';
      expect(
        () => before.withUpdatedGrant(
          ack,
          subjectId: subject,
          permission: HomePersonPermission.readOnly,
        ),
        throwsA(failure('invalid_response')),
      );
      expect(before.grants, isEmpty);
      expect(before.aclRevision, 1);
    }
  });
}
