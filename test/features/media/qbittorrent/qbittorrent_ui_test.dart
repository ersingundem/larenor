import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/dashboard/presentation/tiles/qbittorrent_tile.dart';
import 'package:larenor/features/media/qbittorrent/data/qbittorrent_client.dart';
import 'package:larenor/features/media/qbittorrent/data/qbittorrent_config.dart';
import 'package:larenor/features/media/qbittorrent/presentation/add_torrent_sheet.dart';
import 'package:larenor/features/media/qbittorrent/presentation/qbittorrent_torrents_screen.dart';
import 'package:larenor/features/media/qbittorrent/providers/qbittorrent_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:qbittorrent_api/qbittorrent_api.dart';

const _config = QbittorrentConfig(
  baseUrl: 'http://qb.invalid',
  username: 'fixture',
  password: 'fixture',
);
const _hash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
final _torrent = TorrentInfo.fromJson({
  'hash': _hash,
  'name': 'Family video',
  'state': 'downloading',
});
const _tile = TileConfig(
  id: 'qb',
  type: TileType.qbittorrent,
  x: 0,
  y: 0,
  width: 2,
  height: 2,
);

class _Connection extends QbittorrentConnection {
  @override
  Future<QbittorrentConfig?> build() async => _config;
  void change() => state = const AsyncData(
    QbittorrentConfig(
      baseUrl: 'http://other.invalid',
      username: 'another',
      password: 'another',
    ),
  );
}

class _Files extends TorrentFileAccess {
  _Files(this.select);
  final Future<FileBytes?> Function() select;
  @override
  Future<FileBytes?> pick() => select();
}

class _Harness {
  final connection = _Connection();
  final mutations = <http.Request>[];
  List<TorrentInfo> items = [_torrent];
  bool readFails = false;
  Future<http.Response> Function(http.Request)? mutate;
  TorrentFileAccess files = _Files(() async => null);
  late QbittorrentClient client;
  late ProviderContainer container;

  Future<void> mount(
    WidgetTester tester, {
    bool tile = false,
    Size? size,
    double scale = 1,
  }) async {
    if (size != null) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }
    client = QbittorrentClient(
      config: _config,
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/auth/login')) {
          return http.Response(
            '',
            204,
            headers: {'set-cookie': 'SID=fixture; Path=/; HttpOnly'},
          );
        }
        if (request.url.path.endsWith('/app/version')) {
          return http.Response('v5.2.3', 200);
        }
        if (request.url.path.endsWith('/app/webapiVersion')) {
          return http.Response('2.15.1', 200);
        }
        mutations.add(request);
        return mutate?.call(request) ?? http.Response('', 200);
      }),
    );
    await client.login();
    container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        qbittorrentConnectionProvider.overrideWith(() => connection),
        qbittorrentClientProvider.overrideWith((ref) async => client),
        qbittorrentTorrentsProvider.overrideWith((ref) async {
          if (readFails) throw StateError('private-backend-body');
          return items;
        }),
        torrentFileAccessProvider.overrideWithValue(files),
      ],
    );
    await container.read(qbittorrentConnectionProvider.future);
    addTearDown(() {
      container.dispose();
      client.dispose();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: tile
              ? const CupertinoPageScaffold(
                  child: SizedBox(
                    width: 300,
                    height: 250,
                    child: QbittorrentTile(tile: _tile),
                  ),
                )
              : const QbittorrentTorrentsScreen(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _background(WidgetTester tester) async {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
    await tester.pump();
  }
}

Future<void> _resume(WidgetTester tester) async {
  for (final state in [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
    await tester.pump();
  }
}

void main() {
  testWidgets('5000 torrents build lazily and unknown progress is never zero', (
    tester,
  ) async {
    final harness = _Harness()
      ..items = List.generate(
        5000,
        (index) => TorrentInfo.fromJson({
          'hash': _hash,
          'name': 'Torrent $index',
          'state': 'downloading',
        }),
      );
    await harness.mount(tester);
    expect(find.byType(CupertinoListTile).evaluate().length, lessThan(50));
    expect(find.textContaining('Progress is not reported.'), findsWidgets);
    expect(find.textContaining('0%'), findsNothing);
    expect(find.text('Torrent 4999'), findsNothing);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1000));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoListTile).evaluate().length, lessThan(50));
    expect(tester.takeException(), isNull);
  });

  for (final tile in [false, true]) {
    testWidgets(
      '${tile ? 'tile' : 'list'} shows read failure instead of empty or raw error',
      (tester) async {
        final harness = _Harness()..readFails = true;
        await harness.mount(tester, tile: tile);
        expect(find.text('Could not read service data'), findsOneWidget);
        expect(find.textContaining('private-backend-body'), findsNothing);
        expect(find.text('No torrents'), findsNothing);
        expect(find.text('No active torrents'), findsNothing);
      },
    );
  }

  testWidgets('tile labels missing progress separately from measured zero', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.mount(tester, tile: true);
    expect(find.textContaining('Progress is not reported.'), findsOneWidget);
    expect(find.textContaining('0%'), findsNothing);
  });

  testWidgets('a cached row callback cannot act after its list read fails', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.mount(tester);
    final row = tester
        .widget<CupertinoListTile>(find.byKey(const ValueKey('torrent-row-0')))
        .onTap!;
    harness.readFails = true;
    harness.container.invalidate(qbittorrentTorrentsProvider);
    await tester.pumpAndSettle();
    row();
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoActionSheet), findsNothing);
    expect(harness.mutations, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancel closes the action sheet without a mutation', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.mount(tester);
    await _tap(tester, 'torrent-row-0');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(harness.mutations, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'one pending modal and duplicate action callbacks send one request',
    (tester) async {
      final harness = _Harness();
      final pending = Completer<http.Response>();
      harness.mutate = (_) => pending.future;
      await harness.mount(tester);
      final row = tester
          .widget<CupertinoListTile>(
            find.byKey(const ValueKey('torrent-row-0')),
          )
          .onTap!;
      row();
      row();
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoActionSheet), findsOneWidget);
      final action = tester
          .widget<CupertinoActionSheetAction>(
            find.byKey(const ValueKey('torrent-action-pause')),
          )
          .onPressed;
      action();
      action();
      await tester.pumpAndSettle();
      row();
      expect(harness.mutations.length, 1);
      expect(harness.mutations.single.url.path, endsWith('/torrents/stop'));
      pending.complete(http.Response('', 200));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('qBittorrent accepted the request.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'delete needs named confirmation and always keeps downloaded files',
    (tester) async {
      final harness = _Harness();
      await harness.mount(tester);
      await _tap(tester, 'torrent-row-0');
      await _tap(tester, 'torrent-action-delete');
      expect(harness.mutations, isEmpty);
      expect(find.textContaining('Family video'), findsWidgets);
      expect(
        find.textContaining('Downloaded files will be kept.'),
        findsOneWidget,
      );
      await _tap(tester, 'torrent-confirm-delete');
      expect(harness.mutations.single.bodyFields['deleteFiles'], 'false');
      expect(harness.mutations.single.bodyFields['hashes'], _hash);
    },
  );

  testWidgets('known rejection is caught without exposing backend details', (
    tester,
  ) async {
    final harness = _Harness()
      ..mutate = (_) async => http.Response('private-server-body', 403);
    await harness.mount(tester);
    await _tap(tester, 'torrent-row-0');
    await _tap(tester, 'torrent-action-pause');
    await tester.runAsync(() async {});
    await tester.pumpAndSettle();
    expect(find.text('The request could not be completed'), findsOneWidget);
    expect(find.textContaining('private-server-body'), findsNothing);
    expect(harness.mutations.length, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'uncertain outcome blocks replay until explicit successful refresh',
    (tester) async {
      final harness = _Harness()
        ..mutate = (_) async => throw http.ClientException('private-failure');
      await harness.mount(tester);
      final row = tester
          .widget<CupertinoListTile>(
            find.byKey(const ValueKey('torrent-row-0')),
          )
          .onTap!;
      await _tap(tester, 'torrent-row-0');
      await _tap(tester, 'torrent-action-pause');
      row();
      await tester.pumpAndSettle();
      expect(harness.mutations.length, 1);
      expect(
        find.textContaining('Refresh and check the list before retrying.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<CupertinoListTile>(
              find.byKey(const ValueKey('torrent-row-0')),
            )
            .onTap,
        isNull,
      );
      await _tap(tester, 'torrent-refresh');
      expect(
        tester
            .widget<CupertinoListTile>(
              find.byKey(const ValueKey('torrent-row-0')),
            )
            .onTap,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'account change dismisses the old action sheet and ignores its callback',
    (tester) async {
      final harness = _Harness();
      await harness.mount(tester);
      await _tap(tester, 'torrent-row-0');
      final action = tester
          .widget<CupertinoActionSheetAction>(
            find.byKey(const ValueKey('torrent-action-pause')),
          )
          .onPressed;
      harness.connection.change();
      await tester.pumpAndSettle();
      action();
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoActionSheet), findsNothing);
      expect(find.text('Family video'), findsNothing);
      expect(harness.mutations, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('backgrounding dismisses a magnet draft and its controller', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.mount(tester);
    await _tap(tester, 'torrent-add');
    await _tap(tester, 'torrent-add-magnet');
    final confirm = tester
        .widget<CupertinoDialogAction>(
          find.byKey(const ValueKey('torrent-confirm-magnet')),
        )
        .onPressed!;
    final controller = tester
        .widget<CupertinoTextField>(
          find.byKey(const ValueKey('torrent-magnet-field')),
        )
        .controller!;
    await tester.enterText(
      find.byType(CupertinoTextField),
      'magnet:?xt=urn:btih:$_hash',
    );
    await _background(tester);
    await _resume(tester);
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoTextField), findsNothing);
    expect(() => controller.addListener(() {}), throwsFlutterError);
    // A removed dialog callback must not resurrect or dispatch its draft.
    confirm();
    expect(harness.mutations, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('magnet validation and duplicate confirm send one add', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.mount(tester);
    await _tap(tester, 'torrent-add');
    await _tap(tester, 'torrent-add-magnet');
    await _tap(tester, 'torrent-confirm-magnet');
    expect(find.text('Enter a valid magnet link.'), findsOneWidget);
    expect(harness.mutations, isEmpty);
    await tester.enterText(
      find.byType(CupertinoTextField),
      'magnet:?xt=urn:btih:$_hash',
    );
    final confirm = tester
        .widget<CupertinoDialogAction>(
          find.byKey(const ValueKey('torrent-confirm-magnet')),
        )
        .onPressed!;
    confirm();
    confirm();
    await tester.pumpAndSettle();
    expect(harness.mutations.length, 1);
    expect(harness.mutations.single.url.path, endsWith('/torrents/add'));
    expect(tester.takeException(), isNull);
  });

  for (final cancel in [true, false]) {
    testWidgets(
      'file picker return requires fresh filename confirmation cancel=$cancel',
      (tester) async {
        final harness = _Harness();
        final selection = Completer<FileBytes?>();
        harness.files = _Files(() => selection.future);
        await harness.mount(tester);
        await _tap(tester, 'torrent-add');
        await _tap(tester, 'torrent-add-file');
        await _background(tester);
        await _resume(tester);
        selection.complete(
          FileBytes(
            filename: 'family.torrent',
            bytes: Uint8List.fromList([1, 2, 3]),
          ),
        );
        await tester.pumpAndSettle();
        expect(harness.mutations, isEmpty);
        expect(find.text('Add family.torrent to qBittorrent?'), findsOneWidget);
        if (cancel) {
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
          expect(harness.mutations, isEmpty);
        } else {
          await _tap(tester, 'torrent-confirm-file');
          expect(harness.mutations.length, 1);
          expect(harness.mutations.single.body, contains('family.torrent'));
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'file chooser result after account change cannot confirm or upload',
    (tester) async {
      final harness = _Harness();
      final selection = Completer<FileBytes?>();
      harness.files = _Files(() => selection.future);
      await harness.mount(tester);
      await _tap(tester, 'torrent-add');
      await _tap(tester, 'torrent-add-file');
      harness.connection.change();
      selection.complete(
        FileBytes(filename: 'private.torrent', bytes: Uint8List(1)),
      );
      await tester.pumpAndSettle();
      expect(harness.mutations, isEmpty);
      expect(find.textContaining('private.torrent'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('picker cancellation and failure release the pending guard', (
    tester,
  ) async {
    var picks = 0;
    final harness = _Harness()
      ..files = _Files(() async {
        if (picks++ == 0) return null;
        throw StateError('private-path');
      });
    await harness.mount(tester);
    await _tap(tester, 'torrent-add');
    await _tap(tester, 'torrent-add-file');
    expect(harness.mutations, isEmpty);
    await _tap(tester, 'torrent-add');
    await _tap(tester, 'torrent-add-file');
    expect(find.textContaining('private-path'), findsNothing);
    expect(
      tester
          .widget<CupertinoButton>(find.byKey(const ValueKey('torrent-add')))
          .onPressed,
      isNotNull,
    );
    expect(harness.mutations, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'late mutation failure after disposal has no UI or provider effect',
    (tester) async {
      final harness = _Harness();
      final pending = Completer<http.Response>();
      harness.mutate = (_) => pending.future;
      await harness.mount(tester);
      await _tap(tester, 'torrent-row-0');
      await _tap(tester, 'torrent-action-pause');
      await tester.pumpWidget(const SizedBox());
      pending.complete(http.Response('private', 500));
      await tester.runAsync(() async {});
      await tester.pumpAndSettle();
      expect(harness.mutations.length, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('torrent rows fit 320px width and 2x text', (tester) async {
    final harness = _Harness();
    await harness.mount(tester, size: const Size(320, 900), scale: 2);
    expect(tester.takeException(), isNull);
    await _tap(tester, 'torrent-row-0');
    expect(tester.takeException(), isNull);
  });
}
