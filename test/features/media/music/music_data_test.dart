import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/ha_client/data/ha_api_exception.dart';
import 'package:larenor/features/ha_client/data/ws_client.dart';
import 'package:larenor/features/media/ha_playback/domain/ha_playback_models.dart';
import 'package:larenor/features/media/music/data/music_api.dart';
import 'package:larenor/features/media/music/data/music_parser.dart';
import 'package:larenor/features/media/music/data/music_repository.dart';
import 'package:larenor/features/media/music/domain/music_models.dart';

import 'music_fixtures.dart';

Matcher failure(MusicFailure expected) =>
    isA<MusicException>().having((error) => error.failure, 'failure', expected);
void main() {
  final generation = Object();
  final library = MusicLibraryQuery(
    accountGeneration: generation,
    configEntryId: 'entry',
    type: MusicMediaType.track,
  );
  final search = MusicSearchQuery(
    accountGeneration: generation,
    configEntryId: 'entry',
    text: ' Song ',
  );
  final queue = MusicQueueQuery(
    accountGeneration: generation,
    configEntryId: 'entry',
    entityId: 'media_player.kitchen',
  );
  group('HA response contract', () {
    test(
      'only three documented read services request response and flat data',
      () async {
        final ws = _Ws();
        final api = WsMusicAssistantApi(ws);
        ws.response = musicEntries();
        expect(await api.configEntries(isCurrent: () => true), musicEntries());
        expect(ws.commands.single, {
          'type': 'config_entries/get',
          'domain': 'music_assistant',
        });
        ws.response = {
          'context': {'id': 'safe'},
          'response': musicLibrary(library),
        };
        expect(
          await api.library(library, isCurrent: () => true),
          musicLibrary(library),
        );
        expect(ws.calls.last, {
          'domain': 'music_assistant',
          'service': 'get_library',
          'service_data': {
            'config_entry_id': 'entry',
            'media_type': 'track',
            'limit': 25,
            'offset': 0,
          },
          'return_response': true,
          'target': null,
        });
        ws.response = {'response': musicSearch()};
        await api.search(search, isCurrent: () => true);
        expect(ws.calls.last['service_data'], {
          'config_entry_id': 'entry',
          'name': 'Song',
          'limit': 10,
          'library_only': false,
        });
        ws.response = {'response': musicQueue()};
        expect(
          await api.queue(queue.entityId, isCurrent: () => true),
          musicQueue(),
        );
        expect(ws.calls.last['target'], {
          'entity_id': ['media_player.kitchen'],
        });
        expect(
          ws.calls.every((call) => call['return_response'] == true),
          isTrue,
        );
        ws.dispose();
      },
    );
    test(
      'missing WS response envelope is rejected without private text',
      () async {
        final ws = _Ws()
          ..response = {
            'context': {'secret': 'private-token'},
          };
        expect(
          WsMusicAssistantApi(ws).library(library, isCurrent: () => true),
          throwsA(failure(MusicFailure.invalidResponse)),
        );
        ws.dispose();
      },
    );
    test('typed HA errors never infer from or render private server text', () {
      for (final entry in <String, MusicFailure>{
        'unauthorized': MusicFailure.permission,
        'auth_invalid': MusicFailure.authentication,
        'cancelled': MusicFailure.stale,
        'timeout': MusicFailure.timeout,
        'closed': MusicFailure.transport,
        'unknown_command': MusicFailure.unsupported,
        'home_assistant_error': MusicFailure.unavailable,
      }.entries) {
        final mapped = classifyMusicFailure(
          HaApiException('token=private', code: entry.key),
        );
        expect(mapped, entry.value);
        expect(MusicException(mapped).toString(), isNot(contains('private')));
      }
    });
  });
  test(
    'scoped catalog read rejects a pre-background response after resume',
    () async {
      final api = FakeMusicApi()..libraryGate = Completer<Object?>();
      var epoch = 0;
      final scoped = ScopedMusicAssistantApi(
        api,
        isActive: () => true,
        generation: () => epoch,
      );
      final result = scoped.library(library, isCurrent: () => true);
      epoch += 2;
      api.libraryGate!.complete(musicLibrary(library));
      await expectLater(result, throwsA(failure(MusicFailure.stale)));
    },
  );
  group('bounded parsing', () {
    test('library retains nested titles and opaque reference, omits external images', () {
      final raw = musicLibrary(library);
      (raw['items'] as List)[0] = {
        ...musicItem(),
        'image': 'http://private/token?key=secret',
        'favorite': false,
        'explicit': null,
        'artists': [musicItem(type: MusicMediaType.artist, name: 'Artist')],
        'album': musicItem(type: MusicMediaType.album, name: 'Album'),
      };
      final item = parseMusicLibrary(raw, library).items.single;
      expect(item.artists, ['Artist']);
      expect(item.album, 'Album');
      expect(item.favorite, isFalse);
      expect(item.explicit, isNull);
      expect(item.reference.requestValue, 'library://track/123');
      expect(item.reference.toString(), isNot(contains('library://')));
    });
    test('actual empty library differs from malformed response', () {
      expect(
        parseMusicLibrary({
          ...musicLibrary(library),
          'items': [],
        }, library).items,
        isEmpty,
      );
      expect(
        () => parseMusicLibrary({}, library),
        throwsA(failure(MusicFailure.invalidResponse)),
      );
    });
    test('wrong page/type and too many results are rejected', () {
      for (final update in [
        <String, Object?>{'offset': 20},
        {'limit': 200},
        {'media_type': 'album'},
        {'items': List.generate(26, (_) => musicItem())},
      ]) {
        expect(
          () =>
              parseMusicLibrary({...musicLibrary(library), ...update}, library),
          throwsA(failure(MusicFailure.invalidResponse)),
        );
      }
    });
    test('all seven search groups required and typed', () {
      expect(
        parseMusicSearch(musicSearch(), search).items.single.type,
        MusicMediaType.track,
      );
      final missing = musicSearch()..remove('radio');
      expect(
        () => parseMusicSearch(missing, search),
        throwsA(failure(MusicFailure.invalidResponse)),
      );
      final wrong = musicSearch()..['artists'] = [musicItem()];
      expect(
        () => parseMusicSearch(wrong, search),
        throwsA(failure(MusicFailure.invalidResponse)),
      );
    });
    test('queue unwraps exact entity only, preserves unknown duration', () {
      final raw = musicQueue();
      final row = raw[queue.entityId] as Map;
      (row['current_item'] as Map)['duration'] = null;
      final parsed = parseMusicQueue(raw, queue.entityId);
      expect(parsed.itemCount, 2);
      expect(parsed.current!.durationSeconds, isNull);
      expect(parsed.next, isNull);
      expect(
        () => parseMusicQueue(raw, 'media_player.other'),
        throwsA(failure(MusicFailure.invalidResponse)),
      );
      expect(
        () => parseMusicQueue(row, queue.entityId),
        throwsA(failure(MusicFailure.invalidResponse)),
      );
    });
    test(
      'empty queue count is valid; invalid index and nonfinite number are not',
      () {
        expect(
          parseMusicQueue(musicQueue(count: 0), queue.entityId).itemCount,
          0,
        );
        final raw = musicQueue();
        (raw[queue.entityId] as Map)['current_index'] = 2;
        expect(
          () => parseMusicQueue(raw, queue.entityId),
          throwsA(failure(MusicFailure.invalidResponse)),
        );
        (raw[queue.entityId] as Map)['elapsed_time'] = double.infinity;
        expect(
          () => parseMusicQueue(raw, queue.entityId),
          throwsA(failure(MusicFailure.invalidResponse)),
        );
      },
    );
    test(
      'bounds cover discarded metadata, recursion, payload text, and controls',
      () {
        expect(
          () => validateMusicPayload(List.filled(2001, null)),
          throwsA(failure(MusicFailure.tooLarge)),
        );
        expect(
          () => validateMusicPayload('x' * 16385),
          throwsA(failure(MusicFailure.tooLarge)),
        );
        Object? deep;
        for (var i = 0; i < 14; i++) {
          deep = [deep];
        }
        expect(
          () => validateMusicPayload(deep),
          throwsA(failure(MusicFailure.tooLarge)),
        );
        final raw = musicLibrary(library);
        (raw['items'] as List)[0] = musicItem(name: 'private\nvalue');
        expect(
          () => parseMusicLibrary(raw, library),
          throwsA(failure(MusicFailure.invalidResponse)),
        );
      },
    );
    test(
      'entry discovery rejects duplicate, non MA, malformed disabled flags',
      () {
        expect(parseMusicEntries([]), isEmpty);
        final truncated = musicEntries().single..remove('disabled_by');
        expect(
          () => parseMusicEntries([truncated]),
          throwsA(failure(MusicFailure.invalidResponse)),
        );
        for (final value in [
          [...musicEntries(), ...musicEntries()],
          [
            {...musicEntries().single, 'domain': 'spotify'},
          ],
          [
            {...musicEntries().single, 'disabled_by': false},
          ],
        ]) {
          expect(
            () => parseMusicEntries(value),
            throwsA(failure(MusicFailure.invalidResponse)),
          );
        }
      },
    );
  });
  group('verified selection and lifetime', () {
    late FakeMusicApi api;
    late MusicRepository repository;
    var current = true;
    var now = musicTime;
    setUp(() {
      api = FakeMusicApi();
      current = true;
      now = musicTime;
      repository = MusicRepository(
        api: api,
        accountGeneration: generation,
        isCurrent: () => current,
        now: () => now,
        loadInventory: () async => musicInventory(),
      );
    });
    tearDown(() => repository.close());
    test(
      'no MA is explicit absence and never guesses an installed entry',
      () async {
        api.entries = [];
        expect((await repository.discover()).assistantNotInstalled, isTrue);
        expect(
          repository.library(library),
          throwsA(failure(MusicFailure.invalidSelection)),
        );
        expect(api.libraryReads, 0);
      },
    );
    test('config entry denial is a source failure, not absent MA', () async {
      api.entriesError = HaApiException('secret', code: 'unauthorized');
      final discovery = await repository.discover();
      expect(discovery.assistantNotInstalled, isFalse);
      expect(
        discovery.issues[MusicDiscoverySource.configEntries],
        MusicFailure.permission,
      );
      expect(
        repository.library(library),
        throwsA(failure(MusicFailure.permission)),
      );
      expect(api.libraryReads, 0);
    });
    test(
      'registry denial retains outputs but disables queue selection',
      () async {
        repository.close();
        repository = MusicRepository(
          api: api,
          accountGeneration: generation,
          isCurrent: () => current,
          now: () => now,
          loadInventory: () async => musicInventory(
            registry: false,
            registryFailure: HaPlaybackFailure.permission,
          ),
        );
        final discovery = await repository.discover();
        expect(discovery.inventory!.targets, hasLength(1));
        expect(discovery.queueTargets, isEmpty);
        expect((await repository.library(library)).items, hasLength(1));
        expect(
          repository.queue(queue),
          throwsA(failure(MusicFailure.permission)),
        );
        expect(api.queueReads, 0);
      },
    );
    test(
      'unknown/wrong-generation query makes no discovery or service read',
      () async {
        final query = MusicLibraryQuery(
          accountGeneration: Object(),
          configEntryId: 'entry',
          type: MusicMediaType.track,
        );
        expect(
          repository.library(query),
          throwsA(failure(MusicFailure.invalidSelection)),
        );
        await Future<void>.delayed(Duration.zero);
        expect(api.entryReads, 0);
        expect(api.libraryReads, 0);
      },
    );
    test(
      'disabled entry and unavailable/wrong-integration target cannot query',
      () async {
        api.entries = musicEntries(disabled: 'user');
        expect(
          repository.library(library),
          throwsA(failure(MusicFailure.unavailable)),
        );
        await Future<void>.delayed(Duration.zero);
        expect(api.libraryReads, 0);
        repository.close();
        api.entries = musicEntries();
        repository = MusicRepository(
          api: api,
          accountGeneration: generation,
          isCurrent: () => current,
          now: () => now,
          loadInventory: () async => musicInventory(platform: 'cast'),
        );
        expect(
          repository.queue(queue),
          throwsA(failure(MusicFailure.invalidSelection)),
        );
        await Future<void>.delayed(Duration.zero);
        expect(api.queueReads, 0);
      },
    );
    test(
      'concurrent reads share discovery and aged identity is revalidated',
      () async {
        await Future.wait([
          repository.library(library),
          repository.queue(queue),
        ]);
        expect(api.entryReads, 1);
        now = now.add(const Duration(seconds: 61));
        api.entries = [];
        expect(
          repository.queue(queue),
          throwsA(failure(MusicFailure.invalidSelection)),
        );
        await Future<void>.delayed(Duration.zero);
        expect(api.entryReads, 2);
        expect(api.queueReads, 1);
      },
    );
    test(
      'no retry after timeout; exact typed error survives to caller boundary',
      () async {
        api.libraryError = TimeoutException('private');
        await expectLater(
          repository.library(library),
          throwsA(isA<TimeoutException>()),
        );
        expect(api.libraryReads, 1);
      },
    );
    test(
      'old account discovery and result can never publish after close',
      () async {
        api.entriesGate = Completer<Object?>();
        final discovery = repository.discover();
        current = false;
        api.entriesGate!.complete(musicEntries());
        await expectLater(discovery, throwsA(failure(MusicFailure.stale)));
      },
    );
    test(
      'old account result and background result rejected after await',
      () async {
        api.libraryGate = Completer<Object?>();
        final result = repository.library(library);
        await Future<void>.delayed(Duration.zero);
        expect(api.libraryReads, 1);
        repository.close();
        api.libraryGate!.complete(musicLibrary(library));
        await expectLater(result, throwsA(failure(MusicFailure.stale)));
      },
    );
    test(
      'query bounds reject oversized paging and blank search before IO',
      () async {
        await expectLater(
          repository.library(
            MusicLibraryQuery(
              accountGeneration: generation,
              configEntryId: 'entry',
              type: MusicMediaType.track,
              limit: 501,
            ),
          ),
          throwsA(failure(MusicFailure.invalidSelection)),
        );
        await expectLater(
          repository.search(
            MusicSearchQuery(
              accountGeneration: generation,
              configEntryId: 'entry',
              text: ' ',
            ),
          ),
          throwsA(failure(MusicFailure.invalidSelection)),
        );
        expect(api.entryReads, 0);
      },
    );
  });
}

class _Ws extends HaWebSocketClient {
  _Ws() : super(baseUrl: 'http://example.invalid', token: 'test-only');
  Object? response;
  final commands = <Map<String, dynamic>>[], calls = <Map<String, dynamic>>[];
  @override
  Future<dynamic> sendCommand(
    Map<String, dynamic> command, {
    Duration timeout = const Duration(seconds: 15),
    bool Function()? isCurrent,
  }) async {
    if (isCurrent?.call() == false) {
      throw HaApiException('cancelled', code: 'cancelled');
    }
    commands.add(command);
    return response;
  }

  @override
  Future<dynamic> callService(
    String domain,
    String service, {
    Map<String, dynamic>? serviceData,
    Map<String, dynamic>? target,
    bool returnResponse = false,
    bool Function()? isCurrent,
  }) async {
    if (isCurrent?.call() == false) {
      throw HaApiException('cancelled', code: 'cancelled');
    }
    calls.add({
      'domain': domain,
      'service': service,
      'service_data': serviceData,
      'target': target,
      'return_response': returnResponse,
    });
    return response;
  }
}
