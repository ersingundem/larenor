import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/music_manager/domain/server_music_manager_models.dart';

Map<String, dynamic> _item({
  String uri = 'library://audiobook/book-one',
  String mediaType = 'audiobook',
  double duration = 3600,
  double resume = 900,
  bool fullyPlayed = false,
}) => {
  'uri': uri,
  'name': 'Book one',
  'mediaType': mediaType,
  'providerInstanceId': 'library--main',
  'durationSeconds': duration,
  'resumePositionSeconds': resume,
  'fullyPlayed': fullyPlayed,
  'chapters': [
    {
      'position': 0,
      'name': 'Opening',
      'startSeconds': 0.0,
      'endSeconds': 1200.0,
    },
    {
      'position': 1,
      'name': 'The next part',
      'startSeconds': 1200.0,
      'endSeconds': null,
    },
  ],
};

Map<String, dynamic> _catalog({List<Object?>? items}) => {
  'requestId': 'f' * 32,
  'managerRevision': 6,
  'items': items ?? [_item()],
};

Matcher get _invalid => isA<LarenorServerException>().having(
  (error) => error.code,
  'code',
  'invalid_response',
);

void main() {
  test('strictly parses bounded unfinished longform progress', () {
    final value = ServerMusicLongformCatalog.fromJson(_catalog());

    expect(value.items, hasLength(1));
    expect(value.items.single.progress, 0.25);
    expect(value.items.single.currentChapter?.name, 'Opening');
    expect(value.items.single.chapters.last.endSeconds, isNull);
  });

  test('rejects URLs, secret-like query material and semantic drift', () {
    for (final invalid in [
      _item(uri: 'https://music.example/book?token=secret'),
      _item(uri: 'library://audiobook/book-one?access_token=secret'),
      _item(mediaType: 'podcast'),
      _item(fullyPlayed: true),
      _item(duration: 100, resume: 101),
      {..._item(), 'unexpected': true},
    ]) {
      expect(
        () => ServerMusicLongformCatalog.fromJson(_catalog(items: [invalid])),
        throwsA(_invalid),
      );
    }
  });

  test('rejects duplicate items and invalid chapter ordering', () {
    final invalidChapter = _item();
    invalidChapter['chapters'] = [
      {
        'position': 1,
        'name': 'Out of order',
        'startSeconds': 20.0,
        'endSeconds': 10.0,
      },
    ];

    expect(
      () => ServerMusicLongformCatalog.fromJson(
        _catalog(items: [_item(), _item()]),
      ),
      throwsA(_invalid),
    );
    expect(
      () => ServerMusicLongformCatalog.fromJson(
        _catalog(items: [invalidChapter]),
      ),
      throwsA(_invalid),
    );
    expect(
      () => ServerMusicLongformCatalog.fromJson(
        _catalog(items: List.generate(26, (_) => _item())),
      ),
      throwsA(_invalid),
    );
  });

  test('debug descriptions redact media URI and display text', () {
    final value = ServerMusicLongformCatalog.fromJson(
      _catalog(items: [_item(uri: 'library://audiobook/private-book')]),
    );

    expect(value.toString(), 'ServerMusicLongformCatalog(items: 1)');
    expect(value.items.single.toString(), 'ServerMusicLongformItem(audiobook)');
    expect(value.toString(), isNot(contains('private-book')));
    expect(value.items.single.toString(), isNot(contains('Book one')));
  });
}
