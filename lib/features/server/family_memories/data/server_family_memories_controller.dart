import 'package:flutter/foundation.dart';

import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../domain/server_family_memory_models.dart';
import 'server_family_memories_api.dart';

final class ServerFamilyMemoriesController extends ChangeNotifier {
  ServerFamilyMemoriesController(this.account)
    : _generation = account.generation,
      _accountId = account.session?.user.id,
      _endpoint = account.session?.endpoint.baseUrl {
    account.addListener(_accountChanged);
  }

  final ServerAccountController account;
  final int _generation;
  final String? _accountId, _endpoint;
  int _epoch = 0;
  bool _disposed = false, busy = false, needsRefresh = false;
  String? failure;
  FamilyMemorySnapshot? snapshot;
  List<FamilyMemoryAsset> searchResults = const [];

  bool get _authorized {
    final session = account.session;
    return _accountId != null &&
        account.isCurrent(_generation) &&
        account.initialized &&
        !account.working &&
        session?.user.id == _accountId &&
        session?.endpoint.baseUrl == _endpoint;
  }

  void _accountChanged() {
    if (!_authorized) invalidate();
  }

  void invalidate() {
    _epoch++;
    busy = needsRefresh = false;
    failure = null;
    snapshot = null;
    searchResults = const [];
    _emit();
  }

  Future<void> load({required bool Function() current}) =>
      _run(current, (api) async {
        snapshot = await api.snapshot();
        searchResults = const [];
      });

  Future<void> search({
    required String serviceId,
    required int serviceRevision,
    required String query,
    required List<String> albumIds,
    List<String> personIds = const [],
    required bool Function() current,
  }) => _run(current, (api) async {
    final authority = snapshot?.authority;
    if (authority == null) throw const LarenorServerException('stale_state');
    searchResults = await api.search(
      authority: authority,
      serviceId: serviceId,
      serviceRevision: serviceRevision,
      query: query,
      albumIds: albumIds,
      personIds: personIds,
    );
  });

  Future<void> createAlbum({
    required String title,
    required String visibility,
    required List<String> memberIds,
    required String serviceId,
    required int serviceRevision,
    required bool Function() current,
  }) => _mutation(
    current,
    (api, authority) => api.create(
      authority: authority,
      title: title,
      visibility: visibility,
      memberIds: memberIds,
      serviceId: serviceId,
      serviceRevision: serviceRevision,
    ),
  );

  Future<void> saveSelections(
    FamilyMemoryAlbum album,
    List<FamilyMemorySelection> selections, {
    required bool Function() current,
  }) => _mutation(
    current,
    (api, authority) => api.replaceAssets(authority, album, selections),
  );

  Future<void> updateAlbum(
    FamilyMemoryAlbum album, {
    required String title,
    required String visibility,
    required List<String> memberIds,
    required bool Function() current,
  }) => _mutation(
    current,
    (api, authority) => api.update(
      authority: authority,
      album: album,
      title: title,
      visibility: visibility,
      memberIds: memberIds,
    ),
  );

  Future<void> deleteAlbum(
    FamilyMemoryAlbum album, {
    required bool Function() current,
  }) => _run(current, (api) async {
    final authority = snapshot?.authority;
    if (authority == null || needsRefresh) {
      throw const LarenorServerException('stale_state');
    }
    await api.delete(authority, album);
    snapshot = await api.snapshot();
    searchResults = const [];
  }, mutation: true);

  Future<void> reconcileAlbum(
    FamilyMemoryAlbum album, {
    required bool Function() current,
  }) => _mutation(current, (api, authority) => api.reconcile(authority, album));

  Future<void> _mutation(
    bool Function() current,
    Future<FamilyMemoryAlbum> Function(
      ServerFamilyMemoriesApi api,
      FamilyMemoryAuthority authority,
    )
    action,
  ) => _run(current, (api) async {
    final authority = snapshot?.authority;
    if (authority == null || needsRefresh) {
      throw const LarenorServerException('stale_state');
    }
    await action(api, authority);
    snapshot = await api.snapshot();
    searchResults = const [];
  }, mutation: true);

  Future<void> _run(
    bool Function() current,
    Future<void> Function(ServerFamilyMemoriesApi api) action, {
    bool mutation = false,
  }) async {
    if (_disposed || busy || !_authorized || !current()) return;
    final epoch = _epoch;
    bool valid() => !_disposed && epoch == _epoch && _authorized && current();
    busy = true;
    failure = null;
    _emit();
    try {
      await account.withSession((raw, session) async {
        if (!valid()) throw const LarenorServerException('cancelled');
        await action(ServerFamilyMemoriesApi(raw, session.accessToken));
      });
      if (valid()) needsRefresh = false;
    } catch (error) {
      if (!valid()) return;
      failure = error is LarenorServerException
          ? error.code
          : 'connection_failed';
      if (mutation) needsRefresh = true;
    } finally {
      if (!_disposed && epoch == _epoch) {
        busy = false;
        _emit();
      }
    }
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    account.removeListener(_accountChanged);
    super.dispose();
  }
}
