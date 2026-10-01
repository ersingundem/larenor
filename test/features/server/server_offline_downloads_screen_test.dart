import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/jellyfin/presentation/player/jellyfin_player_screen.dart';
import 'package:larenor/features/media/local_audio/data/local_audio_bridge.dart';
import 'package:larenor/features/media/local_audio/providers/local_audio_providers.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/offline_media/data/server_offline_media_controller.dart';
import 'package:larenor/features/server/offline_media/data/server_offline_media_vault.dart';
import 'package:larenor/features/server/offline_media/domain/server_offline_media_models.dart';
import 'package:larenor/features/server/offline_media/presentation/server_offline_downloads_screen.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:media_kit/media_kit.dart';

const _coreId = '11111111111111111111111111111111';
const _homeId = '22222222222222222222222222222222';
const _accountId = '33333333333333333333333333333333';
const _familyId = '44444444444444444444444444444444';
const _grantId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _itemId = '66666666666666666666666666666666';
final _content = Uint8List.fromList(utf8.encode('offline-video'));

final class _Store implements ServerSessionPersistence {
  _Store(this.value);
  ServerSession? value;

  @override
  Future<ServerSession?> read() async => value;

  @override
  Future<void> write(ServerSession? session) async => value = session;
}

final class _AccountCore {
  _AccountCore._(this.server) {
    _serving = _serve();
  }

  final HttpServer server;
  late final Future<void> _serving;
  final paths = <String>[];
  bool _closed = false;

  static Future<_AccountCore> start() async =>
      _AccountCore._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  String get baseUrl => 'http://127.0.0.1:${server.port}';

  Future<void> _serve() async {
    await for (final request in server) {
      paths.add(request.uri.path);
      await utf8.decoder.bind(request).join();
      switch (request.uri.path) {
        case '/api/v1/auth/me':
          request.response
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode({
                'user': {
                  'id': _accountId,
                  'username': 'traveler',
                  'role': 'member',
                  'mustChangePassword': false,
                },
              }),
            );
        case '/api/v1/context':
          request.response
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode({
                'schemaVersion': 1,
                'coreId': _coreId,
                'homeId': _homeId,
              }),
            );
        case '/api/v1/auth/logout':
          request.response.statusCode = HttpStatus.noContent;
        default:
          request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await server.close(force: true);
    await _serving;
  }
}

ServerSession _session(_AccountCore core) => ServerSession(
  endpoint: ServerEndpoint(core.baseUrl),
  accessToken: 'synthetic_offline_access_token_1234567890',
  refreshToken: 'synthetic_offline_refresh_token_123456789',
  expiresAt: DateTime.utc(2027),
  user: const ServerUser(
    id: _accountId,
    username: 'traveler',
    role: ServerRole.member,
    mustChangePassword: false,
  ),
  sessionFamilyId: _familyId,
  context: ServerContext.fromJson(const {
    'schemaVersion': 1,
    'coreId': _coreId,
    'homeId': _homeId,
  }),
);

ServerOfflineMediaManifest _manifest(ServerSession session) =>
    ServerOfflineMediaManifest.fromJson({
      'schemaVersion': 1,
      'grantId': _grantId,
      'revision': 3,
      'authority': {
        'schemaVersion': 1,
        'coreId': _coreId,
        'homeId': _homeId,
        'accountId': _accountId,
        'accountRevision': 4,
        'sessionFamilyId': _familyId,
        'installationId': '55555555555555555555555555555555',
        'installationRevision': 3,
        'snapshotRevision': 5,
        'jellyfinServiceRevision': 7,
        'itemId': _itemId,
        'mediaKey': 'movie:tmdb:603',
      },
      'title': 'The Matrix',
      'contentLength': _content.length,
      'contentSha256': sha256.convert(_content).toString(),
      'contentType': 'video/mp4',
      'chunkBytes': 16384,
      'downloadedBytes': _content.length,
      'state': 'complete',
      'expiresAt':
          DateTime.now()
              .toUtc()
              .add(const Duration(hours: 1))
              .millisecondsSinceEpoch ~/
          1000,
    }, session: session);

final class _Player extends PlatformPlayer {
  _Player({this.openGate, this.pauseGate})
    : super(configuration: const PlayerConfiguration());

  final Completer<void>? openGate;
  final Completer<void>? pauseGate;

  var opens = 0;
  var stops = 0;
  var pauses = 0;
  var plays = 0;
  var disposes = 0;
  var disposed = false;
  Uri? openedUri;
  final actions = <String>[];
  final seeks = <Duration>[];

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opens++;
    actions.add('open');
    final media = playable as Media;
    openedUri = Uri.parse(media.uri);
    await openGate?.future;
    if (disposed) return;
    playingController.add(play);
    durationController.add(const Duration(minutes: 2));
  }

  @override
  Future<void> stop() async {
    stops++;
    actions.add('stop');
    if (disposed) return;
    playingController.add(false);
  }

  @override
  Future<void> pause() async {
    pauses++;
    actions.add('pause');
    await pauseGate?.future;
    if (disposed) return;
    playingController.add(false);
  }

  @override
  Future<void> play() async {
    plays++;
    actions.add('play');
    if (disposed) return;
    playingController.add(true);
  }

  @override
  Future<void> seek(Duration duration) async {
    actions.add('seek');
    seeks.add(duration);
    if (disposed) return;
    positionController.add(duration);
  }

  void emitError() {
    if (!disposed) errorController.add('private native player detail');
  }

  @override
  Future<void> dispose() async {
    disposes++;
    actions.add('dispose');
    disposed = true;
    await super.dispose();
  }
}

final class _Audio extends LocalAudioBridge {
  _Audio() : super(isAndroid: false);
  var stops = 0;

  @override
  Future<void> stopForVideo() async => stops++;
}

final class _Downloads extends ServerOfflineDownloadsPort {
  _Downloads({required this.list, this.uri, this.opener, this.onRetire});

  final Future<List<ServerOfflineMediaManifest>> Function() list;
  final Uri? uri;
  final Future<Uri?> Function(bool Function() current)? opener;
  final void Function(bool purge)? onRetire;
  var closes = 0;
  var retired = 0;
  bool? lastPurge;

  @override
  Future<List<ServerOfflineMediaManifest>> completed(
    scope, {
    required bool Function() current,
  }) async {
    final result = await list();
    return current() ? result : const [];
  }

  @override
  Future<Uri?> open(scope, manifest, {required bool Function() current}) async {
    final operation = opener;
    if (operation != null) return operation(current);
    return current() ? uri : null;
  }

  @override
  Future<void> closePlayback() async {
    closes++;
  }

  @override
  void retire({required bool purge}) {
    retired++;
    lastPurge = purge;
    onRetire?.call(purge);
  }

  @override
  void dispose() {}
}

Future<ServerAccountController> _account(_AccountCore core) async {
  final account = ServerAccountController(store: _Store(_session(core)));
  await account.initialize();
  expect(account.failure, isNull);
  return account;
}

Widget _app({
  required ServerAccountController account,
  required ServerOfflineDownloadsPort source,
  required _Player platform,
  required _Audio audio,
  Duration localIoTimeout = const Duration(minutes: 10),
  Duration playerOperationTimeout = const Duration(seconds: 5),
}) => ProviderScope(
  overrides: [
    serverAccountControllerProvider.overrideWithValue(account),
    jellyfinPlayerFactoryProvider.overrideWithValue(
      () => Player(platformPlayer: platform),
    ),
    jellyfinVideoSurfaceProvider.overrideWithValue(
      (_) => const SizedBox(key: ValueKey('offline-video-surface')),
    ),
    localAudioBridgeProvider.overrideWithValue(audio),
  ],
  child: CupertinoApp(
    home: ServerOfflineDownloadsScreen(
      scope: account.localMediaScope!,
      source: source,
      localIoTimeout: localIoTimeout,
      playerOperationTimeout: playerOperationTimeout,
    ),
  ),
);

Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  int attempts = 40,
}) async {
  for (var index = 0; index < attempts; index++) {
    await tester.pump(const Duration(milliseconds: 25));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail(
    'Expected widget did not appear; '
    'loading=${find.byKey(const ValueKey('offline-downloads-loading')).evaluate().length}, '
    'error=${find.byKey(const ValueKey('offline-downloads-error')).evaluate().length}, '
    'empty=${find.byKey(const ValueKey('offline-downloads-empty')).evaluate().length}.',
  );
}

void main() {
  setUpAll(() => HttpOverrides.global = null);
  tearDownAll(() => HttpOverrides.global = null);

  test(
    'local-scope controller lists opens and purges without a Core API',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final core = await _AccountCore.start();
      final session = _session(core);
      final account = await _account(core);
      final scope = account.localMediaScope!;
      final root = await Directory.systemTemp.createTemp(
        'offline-local-controller-',
      );
      final vault = ServerOfflineMediaVault(root: () async => root);
      final manifest = _manifest(session);
      await vault.writeChunk(_grantId, 0, _content);
      await vault.storeCompletedManifest(manifest);
      final controller = ServerOfflineMediaController.local(
        account,
        scope,
        vault: vault,
      );
      addTearDown(() async {
        controller.dispose();
        account.dispose();
        await core.close();
        if (await root.exists()) await root.delete(recursive: true);
      });

      final requestsBeforeLocalRead = List<String>.of(core.paths);
      await core.close();
      final completed = await controller.completedForLocalScope(
        scope,
        current: () => true,
      );
      expect(completed.map((item) => item.grantId), [_grantId]);
      final uri = await controller.openCompletedForLocalScope(
        scope,
        completed.single,
        current: () => true,
      );
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final response = await (await client.getUrl(uri!)).close();
      final bytes = await response.fold<List<int>>(
        <int>[],
        (all, chunk) => all..addAll(chunk),
      );
      expect(bytes, _content);
      expect(core.paths, requestsBeforeLocalRead);

      await account.signOut();
      final retained = Directory('${root.path}/$_grantId');
      for (var index = 0; index < 100 && await retained.exists(); index++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(await retained.exists(), isFalse);
    },
  );

  testWidgets('loading resolves to an honest empty inventory', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final core = (await tester.runAsync(_AccountCore.start))!;
    final account = (await tester.runAsync(() => _account(core)))!;
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('offline-screen-empty-'),
    ))!;
    final ready = Completer<List<ServerOfflineMediaManifest>>();
    final source = _Downloads(list: () => ready.future);
    addTearDown(() async {
      account.dispose();
      await core.close();
      if (await root.exists()) await root.delete(recursive: true);
    });

    await tester.pumpWidget(
      _app(
        account: account,
        source: source,
        platform: _Player(),
        audio: _Audio(),
      ),
    );
    expect(find.byKey(const ValueKey('offline-downloads-loading')), findsOne);

    ready.complete(const []);
    await _pumpUntil(
      tester,
      find.byKey(const ValueKey('offline-downloads-empty')),
    );
    expect(find.byKey(const ValueKey('offline-downloads-empty')), findsOne);
  });

  testWidgets(
    'disposing a pending inventory read cancels its owned deadline and rejects its late result',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final core = (await tester.runAsync(_AccountCore.start))!;
      final account = (await tester.runAsync(() => _account(core)))!;
      final session = _session(core);
      final listed = Completer<List<ServerOfflineMediaManifest>>();
      final source = _Downloads(list: () => listed.future);
      addTearDown(() async {
        if (!listed.isCompleted) listed.complete(const []);
        account.dispose();
        await core.close();
      });

      await tester.pumpWidget(
        _app(
          account: account,
          source: source,
          platform: _Player(),
          audio: _Audio(),
        ),
      );
      expect(find.byKey(const ValueKey('offline-downloads-loading')), findsOne);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      listed.complete([_manifest(session)]);
      await tester.pump();

      expect(
        find.byKey(const ValueKey('offline-downloads-list')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('inventory timeout invalidates a late result and offers retry', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final core = (await tester.runAsync(_AccountCore.start))!;
    final session = _session(core);
    final account = (await tester.runAsync(() => _account(core)))!;
    final listed = Completer<List<ServerOfflineMediaManifest>>();
    final source = _Downloads(list: () => listed.future);
    addTearDown(() async {
      if (!listed.isCompleted) listed.complete(const []);
      account.dispose();
      await core.close();
    });

    await tester.pumpWidget(
      _app(
        account: account,
        source: source,
        platform: _Player(),
        audio: _Audio(),
        localIoTimeout: const Duration(milliseconds: 40),
      ),
    );
    await tester.pump(const Duration(milliseconds: 60));
    await _pumpUntil(
      tester,
      find.byKey(const ValueKey('offline-downloads-error')),
    );
    expect(find.byKey(const ValueKey('offline-downloads-retry')), findsOne);

    listed.complete([_manifest(session)]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.byKey(const ValueKey('offline-downloads-error')), findsOne);
    expect(find.byKey(const ValueKey('offline-downloads-list')), findsNothing);
  });

  testWidgets('null local lease becomes an error instead of loading forever', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final core = (await tester.runAsync(_AccountCore.start))!;
    final session = _session(core);
    final account = (await tester.runAsync(() => _account(core)))!;
    final source = _Downloads(list: () async => [_manifest(session)]);
    final player = _Player();
    addTearDown(() async {
      account.dispose();
      await core.close();
    });

    await tester.pumpWidget(
      _app(account: account, source: source, platform: player, audio: _Audio()),
    );
    await _pumpUntil(
      tester,
      find.byKey(const ValueKey('offline-downloads-list')),
    );
    await tester.tap(find.byKey(ValueKey('offline-download-$_grantId')));
    await _pumpUntil(
      tester,
      find.byKey(const ValueKey('offline-player-error')),
    );

    expect(find.byKey(const ValueKey('offline-player-loading')), findsNothing);
    expect(player.opens, 0);
    expect(source.closes, 1);
  });

  testWidgets('late local lease cannot open after scope retirement', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final core = (await tester.runAsync(_AccountCore.start))!;
    final session = _session(core);
    final account = (await tester.runAsync(() => _account(core)))!;
    final opened = Completer<Uri?>();
    final source = _Downloads(
      list: () async => [_manifest(session)],
      opener: (_) => opened.future,
    );
    final player = _Player();
    addTearDown(() async {
      if (!opened.isCompleted) opened.complete(null);
      account.dispose();
      await core.close();
    });

    await tester.pumpWidget(
      _app(account: account, source: source, platform: player, audio: _Audio()),
    );
    await _pumpUntil(
      tester,
      find.byKey(const ValueKey('offline-downloads-list')),
    );
    await tester.tap(find.byKey(ValueKey('offline-download-$_grantId')));
    await tester.pump();
    await tester.runAsync(account.signOut);
    await tester.pump();
    opened.complete(Uri.parse('http://127.0.0.1:9/offline'));
    await tester.pump();
    await tester.pump();

    expect(player.opens, 0);
    expect(source.closes, greaterThanOrEqualTo(1));
    expect(find.byKey(const ValueKey('offline-player-error')), findsOne);
  });

  testWidgets(
    'disposing a pending local lease cancels its deadline and rejects its late URI',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final core = (await tester.runAsync(_AccountCore.start))!;
      final session = _session(core);
      final account = (await tester.runAsync(() => _account(core)))!;
      final opened = Completer<Uri?>();
      final source = _Downloads(
        list: () async => [_manifest(session)],
        opener: (_) => opened.future,
      );
      final player = _Player();
      addTearDown(() async {
        if (!opened.isCompleted) opened.complete(null);
        account.dispose();
        await core.close();
      });

      await tester.pumpWidget(
        _app(
          account: account,
          source: source,
          platform: player,
          audio: _Audio(),
        ),
      );
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey('offline-downloads-list')),
      );
      final navigator = Navigator.of(
        tester.element(find.byKey(const ValueKey('offline-downloads-list'))),
      );
      await tester.tap(find.byKey(ValueKey('offline-download-$_grantId')));
      await tester.pump(const Duration(milliseconds: 500));
      navigator.pop();
      await tester.pumpAndSettle();

      opened.complete(Uri.parse('http://127.0.0.1:9/offline'));
      await tester.pump();
      expect(player.opens, 0);
      expect(source.closes, greaterThanOrEqualTo(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('local lease timeout rejects its late URI and offers retry', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final core = (await tester.runAsync(_AccountCore.start))!;
    final session = _session(core);
    final account = (await tester.runAsync(() => _account(core)))!;
    final opened = Completer<Uri?>();
    final source = _Downloads(
      list: () async => [_manifest(session)],
      opener: (_) => opened.future,
    );
    final player = _Player();
    addTearDown(() async {
      if (!opened.isCompleted) opened.complete(null);
      account.dispose();
      await core.close();
    });

    await tester.pumpWidget(
      _app(
        account: account,
        source: source,
        platform: player,
        audio: _Audio(),
        localIoTimeout: const Duration(milliseconds: 40),
      ),
    );
    await _pumpUntil(
      tester,
      find.byKey(const ValueKey('offline-downloads-list')),
    );
    await tester.tap(find.byKey(ValueKey('offline-download-$_grantId')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    await _pumpUntil(
      tester,
      find.byKey(const ValueKey('offline-player-error')),
    );
    expect(find.byKey(const ValueKey('offline-player-retry')), findsOne);

    opened.complete(Uri.parse('http://127.0.0.1:9/offline'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(player.opens, 0);
    expect(find.byKey(const ValueKey('offline-player-error')), findsOne);
  });

  testWidgets('player open timeout retires and late completion stays fenced', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final core = (await tester.runAsync(_AccountCore.start))!;
    final session = _session(core);
    final account = (await tester.runAsync(() => _account(core)))!;
    final openGate = Completer<void>();
    final source = _Downloads(
      list: () async => [_manifest(session)],
      uri: Uri.parse('http://127.0.0.1:9/offline'),
    );
    final player = _Player(openGate: openGate);
    addTearDown(() async {
      if (!openGate.isCompleted) openGate.complete();
      account.dispose();
      await core.close();
    });

    await tester.pumpWidget(
      _app(
        account: account,
        source: source,
        platform: player,
        audio: _Audio(),
        playerOperationTimeout: const Duration(milliseconds: 40),
      ),
    );
    await _pumpUntil(
      tester,
      find.byKey(const ValueKey('offline-downloads-list')),
    );
    await tester.tap(find.byKey(ValueKey('offline-download-$_grantId')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    await _pumpUntil(
      tester,
      find.byKey(const ValueKey('offline-player-error')),
    );
    expect(player.opens, 1);
    expect(player.stops, greaterThanOrEqualTo(1));

    openGate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.byKey(const ValueKey('offline-player-error')), findsOne);
    expect(find.byKey(const ValueKey('offline-player-toggle')), findsNothing);
    expect(player.plays, 0);
  });

  testWidgets('controls serialize and native error retires without detail', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final core = (await tester.runAsync(_AccountCore.start))!;
    final session = _session(core);
    final account = (await tester.runAsync(() => _account(core)))!;
    final pauseGate = Completer<void>();
    final source = _Downloads(
      list: () async => [_manifest(session)],
      uri: Uri.parse('http://127.0.0.1:9/offline'),
    );
    final player = _Player(pauseGate: pauseGate);
    addTearDown(() async {
      if (!pauseGate.isCompleted) pauseGate.complete();
      account.dispose();
      await core.close();
    });

    await tester.pumpWidget(
      _app(account: account, source: source, platform: player, audio: _Audio()),
    );
    await _pumpUntil(
      tester,
      find.byKey(const ValueKey('offline-downloads-list')),
    );
    await tester.tap(find.byKey(ValueKey('offline-download-$_grantId')));
    await _pumpUntil(
      tester,
      find.byKey(const ValueKey('offline-player-toggle')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('offline-player-toggle')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('offline-player-seek-forward')));
    await tester.pump();
    expect(player.actions, containsAllInOrder(['open', 'pause']));
    expect(player.actions, isNot(contains('seek')));

    pauseGate.complete();
    for (var index = 0; index < 20 && player.seeks.isEmpty; index++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(player.actions, containsAllInOrder(['open', 'pause', 'seek']));

    player.emitError();
    await tester.pump();
    await _pumpUntil(
      tester,
      find.byKey(const ValueKey('offline-player-error')),
    );
    expect(player.stops, greaterThanOrEqualTo(1));
    expect(find.textContaining('private native'), findsNothing);
  });

  testWidgets('dispose drains an in-flight control before stop and dispose', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final core = (await tester.runAsync(_AccountCore.start))!;
    final session = _session(core);
    final account = (await tester.runAsync(() => _account(core)))!;
    final pauseGate = Completer<void>();
    final source = _Downloads(
      list: () async => [_manifest(session)],
      uri: Uri.parse('http://127.0.0.1:9/offline'),
    );
    final player = _Player(pauseGate: pauseGate);
    addTearDown(() async {
      if (!pauseGate.isCompleted) pauseGate.complete();
      account.dispose();
      await core.close();
    });

    await tester.pumpWidget(
      _app(account: account, source: source, platform: player, audio: _Audio()),
    );
    await _pumpUntil(
      tester,
      find.byKey(const ValueKey('offline-downloads-list')),
    );
    await tester.tap(find.byKey(ValueKey('offline-download-$_grantId')));
    await _pumpUntil(
      tester,
      find.byKey(const ValueKey('offline-player-toggle')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('offline-player-toggle')));
    await tester.pump();
    Navigator.of(
      tester.element(find.byKey(const ValueKey('offline-video-surface'))),
    ).pop();
    await tester.pump();
    expect(player.disposed, isFalse);

    pauseGate.complete();
    await tester.pumpAndSettle();
    for (var index = 0; index < 20 && !player.disposed; index++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(player.actions, containsAllInOrder(['pause', 'stop', 'dispose']));
    expect(player.disposes, 1);
  });

  testWidgets(
    'encrypted download opens locally then lifecycle and logout close and purge',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final core = (await tester.runAsync(_AccountCore.start))!;
      final session = _session(core);
      final account = (await tester.runAsync(() => _account(core)))!;
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('offline-screen-player-'),
      ))!;
      final vault = ServerOfflineMediaVault(root: () async => root);
      final manifest = _manifest(session);
      await tester.runAsync(() async {
        await vault.writeChunk(_grantId, 0, _content);
        await vault.storeCompletedManifest(manifest);
      });
      final lease = (await tester.runAsync(
        () => vault.openPlayback(manifest),
      ))!;
      final source = _Downloads(
        list: () async => [manifest],
        uri: lease.uri,
        onRetire: (purge) {
          if (purge) {
            unawaited(
              vault.purgeScope(
                ServerOfflineMediaScope(
                  coreId: _coreId,
                  homeId: _homeId,
                  accountId: _accountId,
                  sessionFamilyId: _familyId,
                ),
              ),
            );
          }
        },
      );
      final player = _Player();
      final audio = _Audio();
      addTearDown(() async {
        account.dispose();
        await lease.close();
        await core.close();
        if (await root.exists()) await root.delete(recursive: true);
      });

      await tester.pumpWidget(
        _app(account: account, source: source, platform: player, audio: audio),
      );
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey('offline-downloads-list')),
      );
      expect(find.byKey(const ValueKey('offline-downloads-list')), findsOne);

      await tester.tap(find.byKey(ValueKey('offline-download-$_grantId')));
      await tester.pump();
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey('offline-video-surface')),
      );
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey('offline-player-toggle')),
      );
      expect(player.opens, 1);
      final localBytes = await tester.runAsync(() async {
        final client = HttpClient();
        try {
          final response = await (await client.getUrl(player.openedUri!))
              .close();
          return await response.fold<List<int>>(
            <int>[],
            (all, chunk) => all..addAll(chunk),
          );
        } finally {
          client.close(force: true);
        }
      });
      expect(localBytes, _content);
      expect(audio.stops, 1);
      expect(find.byKey(const ValueKey('offline-video-surface')), findsOne);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(player.stops, greaterThanOrEqualTo(1));
      expect(source.closes, greaterThanOrEqualTo(1));
      expect(find.byKey(const ValueKey('offline-player-error')), findsOne);

      await tester.runAsync(account.signOut);
      await tester.pump();
      expect(source.lastPurge, isTrue);
      final retained = Directory('${root.path}/$_grantId');
      final purged = await tester.runAsync(() async {
        for (var index = 0; index < 100 && await retained.exists(); index++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        return (
          directory: await retained.exists(),
          key: await const FlutterSecureStorage().read(
            key: 'larenor.offline-media.v1.$_grantId',
          ),
        );
      });
      expect(purged?.directory, isFalse);
      expect(purged?.key, isNull);
    },
  );

  testWidgets('tampered completed envelope is an error, never an empty list', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final core = (await tester.runAsync(_AccountCore.start))!;
    final session = _session(core);
    final account = (await tester.runAsync(() => _account(core)))!;
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('offline-screen-bad-'),
    ))!;
    final vault = ServerOfflineMediaVault(root: () async => root);
    await tester.runAsync(() async {
      await vault.writeChunk(_grantId, 0, _content);
      await vault.storeCompletedManifest(_manifest(session));
      final stored = File('${root.path}/$_grantId/completed.manifest.v1');
      final bytes = await stored.readAsBytes();
      bytes[bytes.length - 1] ^= 1;
      await stored.writeAsBytes(bytes, flush: true);
    });
    final localScope = ServerOfflineMediaScope(
      coreId: _coreId,
      homeId: _homeId,
      accountId: _accountId,
      sessionFamilyId: _familyId,
    );
    Object? integrityError;
    await tester.runAsync(() async {
      try {
        await vault.completed(localScope);
      } catch (error) {
        integrityError = error;
      }
    });
    expect(integrityError, isNotNull);
    final source = _Downloads(list: () => Future.error(integrityError!));
    addTearDown(() async {
      account.dispose();
      await core.close();
      if (await root.exists()) await root.delete(recursive: true);
    });

    await tester.pumpWidget(
      _app(
        account: account,
        source: source,
        platform: _Player(),
        audio: _Audio(),
      ),
    );
    await _pumpUntil(
      tester,
      find.byKey(const ValueKey('offline-downloads-error')),
    );

    expect(find.byKey(const ValueKey('offline-downloads-error')), findsOne);
    expect(find.byKey(const ValueKey('offline-downloads-empty')), findsNothing);
  });
}
