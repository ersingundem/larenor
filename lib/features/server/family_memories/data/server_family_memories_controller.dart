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
  FamilyMemorySourceState? source;
  List<FamilyMemorySourceAlbum> availableSourceAlbums = const [];
  bool get isOwnSource => source?.accountId == _accountId;
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
    source = null;
    availableSourceAlbums = const [];
    searchResults = const [];
    _emit();
  }

  Future<void> load({required bool Function() current}) =>
      _run(current, (api, valid) async {
        final nextSource = await api.sources();
        if (!valid()) return;
        final next = nextSource.binding == null ? null : await api.snapshot();
        if (!valid()) return;
        _checkSnapshot(nextSource, next);
        source = nextSource;
        availableSourceAlbums = nextSource.albums;
        snapshot = next;
        searchResults = const [];
      });

  Future<void> search({
    required String serviceId,
    required int serviceRevision,
    required String query,
    required List<String> albumIds,
    List<String> personIds = const [],
    required bool Function() current,
  }) => _run(current, (api, valid) async {
    final authority = snapshot?.authority;
    if (authority == null || needsRefresh || !isOwnSource) {
      throw const LarenorServerException('stale_state');
    }
    final next = await api.search(
      authority: authority,
      serviceId: serviceId,
      serviceRevision: serviceRevision,
      query: query,
      albumIds: albumIds,
      personIds: personIds,
    );
    if (valid()) searchResults = next;
  });

  Future<void> loadSource(
    String accountId, {
    required bool Function() current,
  }) => _run(current, (api, valid) async {
    final next = await api.sources(accountId: accountId);
    if (!valid()) return;
    source = next;
    availableSourceAlbums = next.albums;
    if (next.accountId != _accountId) {
      snapshot = null;
      searchResults = const [];
    }
  });

  Future<void> loadSourceAlbums(
    FamilyMemorySourceService service, {
    required bool Function() current,
  }) => _run(current, (api, valid) async {
    availableSourceAlbums = const [];
    final next = await api.sourceAlbums(service);
    if (valid()) availableSourceAlbums = next;
  });

  Future<void> grantSource(
    FamilyMemorySourceService service,
    List<String> albumIds, {
    required bool Function() current,
  }) => _sourceMutation(
    current,
    (api, state) => api.grantSource(state, service, albumIds),
  );

  Future<void> revokeSource({required bool Function() current}) =>
      _sourceMutation(current, (api, state) => api.revokeSource(state));

  Future<void> faceConsent(bool enabled, {required bool Function() current}) =>
      _sourceMutation(current, (api, state) {
        if (!isOwnSource) throw const LarenorServerException('forbidden');
        return api.faceConsent(state, enabled);
      });

  Future<void> _sourceMutation(
    bool Function() current,
    Future<FamilyMemorySourceState> Function(
      ServerFamilyMemoriesApi,
      FamilyMemorySourceState,
    )
    action,
  ) => _run(current, (api, valid) async {
    final state = source;
    if (state == null || needsRefresh) {
      throw const LarenorServerException('stale_state');
    }
    final next = await action(api, state);
    if (!valid()) return;
    // The mutation has reached Core. Retire previous selections even if the
    // dependent refreshed snapshot is subsequently unavailable.
    snapshot = null;
    searchResults = const [];
    final nextSnapshot = next.accountId == _accountId && next.binding != null
        ? await api.snapshot()
        : null;
    if (!valid()) return;
    _checkSnapshot(next, nextSnapshot);
    source = next;
    availableSourceAlbums = next.albums;
    snapshot = nextSnapshot;
    searchResults = const [];
  }, mutation: true);

  void _checkSnapshot(
    FamilyMemorySourceState state,
    FamilyMemorySnapshot? next,
  ) {
    if (next == null) return;
    final binding = state.binding;
    if (next.authority.accountId != _accountId ||
        next.authority.accountId != state.accountId ||
        next.authority.sessionId != account.session?.sessionFamilyId ||
        binding == null ||
        binding.serviceId != next.binding.serviceId ||
        binding.serviceRevision != next.binding.serviceRevision ||
        binding.faceSearchEnabled != next.binding.faceSearchEnabled ||
        !listEquals(binding.allowedAlbumIds, next.binding.allowedAlbumIds)) {
      throw const LarenorServerException('stale_state');
    }
  }

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
  }) => _run(current, (api, valid) async {
    final authority = snapshot?.authority;
    if (authority == null || needsRefresh) {
      throw const LarenorServerException('stale_state');
    }
    await api.delete(authority, album);
    if (!valid()) return;
    final next = await api.snapshot();
    if (!valid()) return;
    snapshot = next;
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
  ) => _run(current, (api, valid) async {
    final authority = snapshot?.authority;
    if (authority == null || needsRefresh) {
      throw const LarenorServerException('stale_state');
    }
    await action(api, authority);
    if (!valid()) return;
    final next = await api.snapshot();
    if (!valid()) return;
    snapshot = next;
    searchResults = const [];
  }, mutation: true);

  Future<void> _run(
    bool Function() current,
    Future<void> Function(ServerFamilyMemoriesApi api, bool Function() valid)
    action, {
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
        await action(ServerFamilyMemoriesApi(raw, session.accessToken), valid);
      });
      if (valid()) needsRefresh = false;
    } catch (error) {
      if (!valid()) return;
      failure = error is LarenorServerException
          ? error.code
          : 'connection_failed';
      needsRefresh = true;
      snapshot = null;
      searchResults = const [];
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
