import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/home_data_scope.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout_validation.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/features/home_scope/domain/core_layout_archive.dart';

HomeDataScope scope({String? core, String? home, String user = 'member-one'}) =>
    HomeDataScope.fromJson({
      'coreId': core ?? 'a' * 32,
      'homeId': home ?? 'b' * 32,
      'userId': user,
    });

final capturedAt = DateTime.utc(2026, 9, 6, 12, 30, 1, 234);

Map<String, dynamic> archiveJson() => {
  'kind': 'core-room-layout',
  'version': 1,
  'capturedAt': '2026-09-06T12:30:01.234Z',
  'scopeDigest': sha256
      .convert(
        utf8.encode(
          jsonEncode([
            'larenor-core-layout-archive-scope-v1',
            'a' * 32,
            'b' * 32,
            'member-one',
          ]),
        ),
      )
      .toString(),
  'sourceRevision': 7,
  'rooms': [
    {'id': 'room-b', 'name': 'Çalışma odası'},
    {'id': 'room-a', 'name': ' Living room 🏡 '},
  ],
};

Matcher archiveError(String code) => throwsA(
  isA<CoreLayoutArchiveException>().having((error) => error.code, 'code', code),
);

CoreLayoutArchiveV1 capture(Object? layout, {int revision = 7}) =>
    CoreLayoutArchiveV1.fromScopedLayout(
      scope: scope(),
      sourceRevision: revision,
      capturedAt: capturedAt,
      layout: layout,
    );

void main() {
  test('actual passive DashboardLayout preserves IDs, names and order', () {
    const layout = DashboardLayout(
      rooms: [
        DashboardRoom(id: 'room-b', name: 'Çalışma odası'),
        DashboardRoom(id: 'room-a', name: ' Living room 🏡 '),
      ],
    );
    final archive = capture(layout.toJson());
    expect(archive.toJson(), archiveJson());
    expect(archive.rooms.map((room) => room.id), ['room-b', 'room-a']);
    expect(archive.rooms.last.name, ' Living room 🏡 ');
    expect(archive.capturedAt, capturedAt);
    expect(archive.sourceRevision, 7);
    expect(archive.matchesScope(scope()), isTrue);
    expect(
      CoreLayoutArchiveV1.decode(archive.encode()).toJson(),
      archiveJson(),
    );
  });

  test('digest binds the full tuple without exporting identity or credentials', () {
    final archive = CoreLayoutArchiveV1.fromJson(archiveJson());
    for (final other in [
      scope(core: 'c' * 32),
      scope(home: 'c' * 32),
      scope(user: 'member-two'),
    ]) {
      expect(archive.matchesScope(other), isFalse);
    }
    expect(archive.scopeDigest, archiveJson()['scopeDigest']);
    expect(archive.scopeDigest, isNot(scope().storageKey.split('_').last));
    for (final private in ['member-one', 'a' * 32, 'b' * 32, 'coreId', 'userId']) {
      expect(archive.encode(), isNot(contains(private)));
    }
    expect(archive.toString(), 'CoreLayoutArchiveV1');
    expect(archive.rooms.first.toString(), 'CoreLayoutArchiveRoom');
  });

  test('original nested values and exported maps cannot mutate the model', () {
    final input = archiveJson();
    final archive = CoreLayoutArchiveV1.fromJson(input);
    final original = archive.encode();
    (input['rooms'] as List).first['name'] = 'Changed original';
    (input['rooms'] as List).clear();
    final output = archive.toJson();
    (output['rooms'] as List).first['id'] = 'Changed output';
    (output['rooms'] as List).clear();
    expect(archive.encode(), original);
    expect(() => archive.rooms.clear(), throwsUnsupportedError);
  });

  test('source layout alias cannot change a captured passive profile', () {
    final source = <String, dynamic>{
      'rooms': [
        {'id': 'one', 'name': 'One', 'entityIds': <String>[]},
      ],
    };
    final archive = capture(source);
    source['rooms'][0]['name'] = 'Changed';
    source['rooms'][0]['entityIds'].add('light.new');
    expect(archive.rooms.single.name, 'One');
    expect(archive.toJson()['rooms'], [
      {'id': 'one', 'name': 'One'},
    ]);
  });

  test('empty and 500-room layouts retain all records', () {
    expect(capture(const DashboardLayout().toJson()).rooms, isEmpty);
    final rooms = List.generate(500, (i) => {'id': 'room-$i', 'name': 'Room $i'});
    final archive = capture({'rooms': rooms});
    expect(archive.rooms.length, 500);
    expect(archive.rooms.last.id, 'room-499');
    expect(CoreLayoutArchiveV1.decode(archive.encode()).rooms.length, 500);
  });

  test('passive schema v1 source is explicit conversion, not legacy backup', () {
    final archive = capture({'schemaVersion': 1, 'rooms': [{'id': 'one', 'name': 'One'}]});
    expect(archive.toJson()['kind'], 'core-room-layout');
    expect(archive.toJson().containsKey('schemaVersion'), isFalse);
    expect(maxCoreLayoutArchiveBytes, maxDashboardLayoutBytes);
  });

  for (final revision in [0, 1, 9223372036854775806]) {
    test('source revision $revision is informational and preserved', () {
      final archive = CoreLayoutArchiveV1.fromJson({
        ...archiveJson(),
        'sourceRevision': revision,
      });
      expect(archive.sourceRevision, revision);
      expect(archive.matchesScope(scope()), isTrue);
    });
  }

  for (final text in ['a' * 256, '🏡' * 128, ' ']) {
    test('existing 256 UTF16-unit room bound is preserved: ${text.length}', () {
      final input = {...archiveJson(), 'rooms': [{'id': text, 'name': text}]};
      final archive = CoreLayoutArchiveV1.fromJson(input);
      validateDashboardLayoutJson({'rooms': input['rooms']});
      expect(archive.rooms.single.id, text);
      expect(archive.rooms.single.name, text);
    });
  }

  final invalidRoots = <Object?>[
    null,
    [],
    'private-input',
    {...archiveJson(), 'kind': 'larenor-vault'},
    {...archiveJson(), 'kind': null},
    {...archiveJson(), 'version': 2},
    {...archiveJson(), 'version': true},
    {...archiveJson(), 'version': 1.0},
    {...archiveJson(), 'sourceRevision': true},
    {...archiveJson(), 'sourceRevision': 1.0},
    {...archiveJson(), 'sourceRevision': -1},
    {...archiveJson(), 'sourceRevision': 9223372036854775807},
    {...archiveJson(), 'sourceRevision': '7'},
    {...archiveJson(), 'scopeDigest': 'A' * 64},
    {...archiveJson(), 'scopeDigest': 'a' * 63},
    {...archiveJson(), 'scopeDigest': '${'a' * 63}\n'},
    {...archiveJson(), 'scopeDigest': {'scope': 'private-input'}},
    {...archiveJson(), 'capturedAt': '2026-09-06T12:30:01Z'},
    {...archiveJson(), 'capturedAt': '2026-09-06T12:30:01.234+00:00'},
    {...archiveJson(), 'capturedAt': '2026-02-30T12:30:01.234Z'},
    {...archiveJson(), 'capturedAt': '2026-09-06T12:30:01.234567Z'},
    {...archiveJson(), 'capturedAt': 1},
    {...archiveJson(), 'rooms': null},
    {...archiveJson(), 'rooms': {}},
    {...archiveJson(), 'rooms': [null]},
    {...archiveJson(), 'rooms': [{'id': 'one', 'name': {'value': 'One'}}]},
    {...archiveJson(), 'rooms': [{'id': 'one'}]},
    {...archiveJson(), 'rooms': [{'id': 1, 'name': 'One'}]},
    {...archiveJson(), 'rooms': [
      {'id': 'one', 'name': 'One'},
      {'id': 'one', 'name': 'Another'},
    ]},
    {...archiveJson(), 'rooms': List.generate(501, (i) => {'id': '$i', 'name': '$i'})},
    for (final key in archiveJson().keys) {...archiveJson()}..remove(key),
    for (final key in ['homeId', 'userId', 'session', 'scope', 'layout', 'preferences', 'journal', 'order'])
      {...archiveJson(), key: 'private-input'},
    for (final key in ['entityIds', 'areaBinding', 'url', 'webPanel', 'unknown'])
      {...archiveJson(), 'rooms': [{'id': 'one', 'name': 'One', key: null}]},
    for (final key in ['id', 'name'])
      for (final value in ['', 'a' * 257, '🏡' * 129, 'bad\nvalue', 'bad\u007fvalue'])
        {...archiveJson(), 'rooms': [{'id': 'one', 'name': 'One', key: value}]},
  ];
  for (final (index, value) in invalidRoots.indexed) {
    test('closed archive rejects malformed or forbidden input $index', () {
      expect(() => CoreLayoutArchiveV1.fromJson(value), archiveError('invalid_archive'));
    });
  }

  test('parser bounds actual UTF8 bytes including otherwise legal whitespace', () {
    final raw = jsonEncode(archiveJson());
    expect(utf8.encode(raw).length, greaterThan(raw.length));
    final padded = raw + ' ' * (maxCoreLayoutArchiveBytes - utf8.encode(raw).length);
    expect(utf8.encode(padded).length, maxCoreLayoutArchiveBytes);
    expect(CoreLayoutArchiveV1.decode(padded).rooms.length, 2);
    expect(() => CoreLayoutArchiveV1.decode('$padded '), archiveError('archive_too_large'));
  });

  for (final value in ['', '{', '{"secret":"private-input"}', '[1]']) {
    test('decode rejects incomplete or unrelated JSON ${value.length}', () {
      expect(() => CoreLayoutArchiveV1.decode(value), archiveError('invalid_archive'));
    });
  }

  final unsupportedSources = <Object?>[
    null,
    [],
    {'unknown': 'private-input'},
    {'schemaVersion': 3},
    {'rooms': [{'id': 'one', 'name': 'One', 'unknown': 'private-input'}]},
    {'rooms': [{'id': 'one', 'name': 'One', 'entityIds': ['light.one']}]},
    {'rooms': [{'id': 'one', 'name': 'One', 'areaBinding': {'serverUrl': 'https://example.invalid'}}]},
    {'rooms': [{'id': 'one', 'name': 'One', 'url': 'https://example.invalid'}]},
    {'favoriteEntityIds': ['light.one']},
    {'hiddenEntityIds': ['light.one']},
    {'entityCardSizes': {'light.one': 'large'}},
    {'serviceCardSizes': {'sonarr': 'large'}},
    {'tiles': [{'id': 'tile', 'type': 'webview', 'x': 0, 'y': 0, 'width': 1, 'height': 1, 'url': 'https://example.invalid'}]},
    {'webPanelUrl': 'https://example.invalid'},
    {'rooms': null},
    {'tiles': null},
    {'entityCardSizes': null},
    {'rooms': [{'id': 'one', 'name': 'One', 'entityIds': null}]},
  ];
  for (final (index, value) in unsupportedSources.indexed) {
    test('source rejects unsupported content without trimming $index', () {
      expect(() => capture(value), archiveError('unsupported_layout'));
    });
  }

  test('valid source with populated HA binding is explicitly unsupported', () {
    final source = {
      'rooms': [
        {
          'id': 'one',
          'name': 'One',
          'entityIds': <String>[],
          'areaBinding': {
            'serverUrl': 'https://ha.example.invalid',
            'areaId': 'office',
            'sourceName': 'Office',
            'importedEntityIds': <String>[],
            'excludedEntityIds': <String>[],
          },
        },
      ],
    };
    validateDashboardLayoutJson(source);
    expect(() => capture(source), archiveError('unsupported_layout'));
  });

  test('otherwise valid web panel URL and origin preferences are not dropped', () {
    final source = {
      'tiles': [
        {
          'id': 'tile', 'type': 'webview', 'x': 0, 'y': 0, 'width': 1, 'height': 1,
          'url': 'https://example.invalid',
          'webPanel': {
            'additionalOrigins': <String>[], 'zoomEnabled': true, 'textZoom': 100,
          },
        },
      ],
    };
    validateDashboardLayoutJson(source);
    expect(() => capture(source), archiveError('unsupported_layout'));
  });

  test('source factory rejects noncanonical capture time and invalid revision', () {
    for (final time in [DateTime(2026, 9, 6), DateTime.utc(2026, 9, 6, 0, 0, 0, 0, 1)]) {
      expect(
        () => CoreLayoutArchiveV1.fromScopedLayout(
          scope: scope(), sourceRevision: 7, capturedAt: time, layout: {'rooms': []},
        ),
        archiveError('invalid_archive'),
      );
    }
    expect(() => capture({'rooms': []}, revision: -1), archiveError('invalid_archive'));
  });

  test('exceptions disclose only static code', () {
    try {
      CoreLayoutArchiveV1.decode('{"token":"private-input"}');
      fail('must reject');
    } on CoreLayoutArchiveException catch (error) {
      expect(error.toString(), 'CoreLayoutArchiveException(invalid_archive)');
      expect(error.toString(), isNot(contains('private-input')));
    }
  });
}
