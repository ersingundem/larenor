import 'package:qbittorrent_api/qbittorrent_api.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../data/media_api_exception.dart';
import '../data/qbittorrent_config.dart';
import '../data/qbittorrent_credentials_store.dart';

part 'qbittorrent_providers.g.dart';

@riverpod
QbittorrentCredentialsStore qbittorrentCredentialsStore(Ref ref) =>
    QbittorrentCredentialsStore();

@riverpod
class QbittorrentConnection extends _$QbittorrentConnection {
  @override
  Future<QbittorrentConfig?> build() =>
      ref.watch(qbittorrentCredentialsStoreProvider).read();

  Future<void> signIn({
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    final api = QBittorrentApiV2(baseUrl: baseUrl);
    try {
      await api.auth.login(username: username, password: password);
    } catch (_) {
      throw MediaApiException('Could not sign in — check URL and credentials.');
    }

    await ref
        .read(qbittorrentCredentialsStoreProvider)
        .save(baseUrl: baseUrl, username: username, password: password);
    state = AsyncData(
      QbittorrentConfig(
        baseUrl: baseUrl,
        username: username,
        password: password,
      ),
    );
  }

  Future<void> signOut() async {
    await ref.read(qbittorrentCredentialsStoreProvider).clear();
    state = const AsyncData(null);
  }
}

@riverpod
Future<QBittorrentApiV2?> qbittorrentClient(Ref ref) async {
  final config = ref.watch(qbittorrentConnectionProvider).value;
  if (config == null) return null;

  final api = QBittorrentApiV2(baseUrl: config.baseUrl);
  await api.auth.login(username: config.username, password: config.password);
  return api;
}

@riverpod
Future<List<TorrentInfo>> qbittorrentTorrents(Ref ref) async {
  final client = await ref.watch(qbittorrentClientProvider.future);
  if (client == null) return [];
  return client.torrents.getTorrentsList(options: const TorrentListOptions());
}
