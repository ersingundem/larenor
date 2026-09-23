import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../../music_retained/data/server_music_retained_api.dart';
import '../../music_retained/domain/server_music_retained_models.dart';
import '../domain/server_music_manager_models.dart';
import 'server_music_manager_cache.dart';
import 'server_music_command_receipt_cache.dart';
import 'server_music_manager_api.dart';
import 'server_music_selection_cache.dart';

const _managerFallbackFailures = {
  'connection_failed',
  'timeout',
  'server_error',
  'rate_limited',
};

class ServerMusicManagerController extends ChangeNotifier {
  ServerMusicManagerController(
    this.account, {
    String Function()? requestId,
    ServerMusicManagerCache? cache,
    ServerMusicSelectionCache? selectionCache,
    ServerMusicCommandReceiptCache? receiptCache,
  }) : _accountEpoch = account.generation,
       _requestId = requestId ?? _randomId,
       _cache = cache ?? ServerMusicManagerCache(),
       _selectionCache = selectionCache ?? ServerMusicSelectionCache(),
       _receiptCache = receiptCache ?? ServerMusicCommandReceiptCache() {
    account.addListener(_accountChanged);
  }

  final ServerAccountController account;
  final int _accountEpoch;
  final String Function() _requestId;
  final ServerMusicManagerCache _cache;
  final ServerMusicSelectionCache _selectionCache;
  final ServerMusicCommandReceiptCache _receiptCache;
  int _epoch = 0;
  int _selectionEpoch = 0;
  int _longformEpoch = 0;
  bool _disposed = false;

  bool busy = false;
  bool stored = false;
  bool reachable = false;
  bool verified = false;
  String? failure;
  ServerMusicRetainedInstallation? installation;
  ServerMusicManager? manager;
  ServerMusicCatalog? catalog;
  ServerMusicLongformCatalog? longform;
  bool longformBusy = false;
  String? longformFailure;
  String? selectedProviderId;
  String? selectedReceiverId;
  String? selectedMediaUri;
  ServerMusicReceipt? lastReceipt;

  static String _randomId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  bool get _authorized =>
      account.isCurrent(_accountEpoch) &&
      account.initialized &&
      !account.working &&
      account.session?.user.canAdminister == true;

  ServerMusicProviderBinding? get selectedProvider {
    final id = selectedProviderId;
    return id == null
        ? null
        : manager?.providers.where((item) => item.setupId == id).firstOrNull;
  }

  ServerMusicReceiver? get selectedReceiver {
    final id = selectedReceiverId;
    return id == null
        ? null
        : manager?.receivers.where((item) => item.id == id).firstOrNull;
  }

  ServerMusicCatalogItem? get selectedMedia {
    final uri = selectedMediaUri;
    return uri == null
        ? null
        : catalog?.items.where((item) => item.uri == uri).firstOrNull;
  }

  ServerMusicQueue? get selectedQueue {
    final receiver = selectedReceiver;
    return receiver == null ? null : manager?.queueFor(receiver);
  }

  void _accountChanged() {
    if (!_authorized) invalidate();
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void invalidate() {
    _epoch++;
    _selectionEpoch++;
    _longformEpoch++;
    busy = false;
    stored = false;
    reachable = false;
    verified = false;
    failure = null;
    installation = null;
    manager = null;
    catalog = null;
    longform = null;
    longformBusy = false;
    longformFailure = null;
    selectedProviderId = null;
    selectedReceiverId = null;
    selectedMediaUri = null;
    lastReceipt = null;
    _emit();
  }

  bool _sameAuthority(
    ServerMusicManager value,
    ServerMusicRetainedInstallation retained,
  ) =>
      value.installationId == retained.installationId &&
      value.installationRevision == retained.installationRevision &&
      value.coreRevision == retained.bootstrap?.revision;

  void _acceptManager(
    ServerMusicManager value, {
    required bool isVerified,
    bool isReachable = true,
  }) {
    final retained = installation;
    if (retained == null || !_sameAuthority(value, retained)) {
      throw const LarenorServerException('stale');
    }
    manager = value;
    reachable = isReachable;
    verified = isVerified;
    selectedProviderId = value.providers
        .where((item) => item.setupId == selectedProviderId)
        .firstOrNull
        ?.setupId;
    selectedProviderId ??= value.providers.firstOrNull?.setupId;
    selectedReceiverId = value.receivers
        .where((item) => item.id == selectedReceiverId)
        .firstOrNull
        ?.id;
    selectedReceiverId ??= value.receivers
        .where((item) => item.available && item.enabled)
        .firstOrNull
        ?.id;
    if (catalog?.managerRevision != value.revision) {
      catalog = null;
      selectedMediaUri = null;
    }
    if (longform?.managerRevision != value.revision) {
      _longformEpoch++;
      longform = null;
      longformBusy = false;
      longformFailure = null;
    }
  }

  Future<void> load({required bool Function() current}) async {
    if (_disposed || busy || !_authorized || !current()) return;
    final epoch = ++_epoch;
    bool valid() => !_disposed && epoch == _epoch && _authorized && current();
    busy = true;
    failure = null;
    stored = false;
    reachable = false;
    verified = false;
    installation = null;
    manager = null;
    catalog = null;
    _longformEpoch++;
    longform = null;
    longformBusy = false;
    longformFailure = null;
    lastReceipt = null;
    _emit();
    try {
      await account.withSession((api, session) async {
        final overview = await ServerMusicRetainedApi(
          api,
          session.accessToken,
        ).read();
        if (!valid()) return;
        final retained = overview.installations
            .where(
              (item) =>
                  item.state == 'ready' &&
                  item.bootstrap?.state == 'ready' &&
                  item.providers.any((provider) => provider.state == 'ready'),
            )
            .firstOrNull;
        if (retained == null) {
          failure = 'not_configured';
          return;
        }
        installation = retained;
        stored = true;
        _emit();
        final scope = ServerMusicManagerCacheScope.fromSession(session);
        final cached = await _cache.read(
          scope,
          installationId: retained.installationId,
          installationRevision: retained.installationRevision,
          coreRevision: retained.bootstrap!.revision,
        );
        if (!valid()) return;
        try {
          final value = await ServerMusicManagerApi(
            api,
            session.accessToken,
          ).read(retained.installationId);
          if (valid()) {
            _acceptManager(value, isVerified: false);
            await _writeCache(scope, value, valid);
          }
        } on LarenorServerException catch (error) {
          if (error.code == 'unauthorized') rethrow;
          if (valid()) {
            failure = error.code;
            if (cached != null &&
                _managerFallbackFailures.contains(error.code)) {
              _acceptManager(cached, isVerified: false, isReachable: false);
            }
          }
        }
      });
    } catch (error) {
      if (valid()) {
        failure = error is LarenorServerException
            ? error.code
            : 'connection_failed';
      }
    } finally {
      if (!_disposed && epoch == _epoch) {
        busy = false;
        _emit();
      }
    }
  }

  Future<void> _writeCache(
    ServerMusicManagerCacheScope scope,
    ServerMusicManager value,
    bool Function() valid,
  ) async {
    if (!valid()) return;
    try {
      await _cache.write(scope, value, isCurrent: valid);
    } catch (_) {}
  }

  Future<void> verify({required bool Function() current}) async {
    final retained = installation;
    if (_disposed || busy || !_authorized || !current() || retained == null) {
      return;
    }
    final epoch = _epoch;
    bool valid() =>
        !_disposed &&
        epoch == _epoch &&
        _authorized &&
        current() &&
        identical(installation, retained);
    busy = true;
    _longformEpoch++;
    longform = null;
    longformBusy = false;
    longformFailure = null;
    failure = null;
    verified = false;
    _emit();
    try {
      await account.withSession((api, session) async {
        final value = await ServerMusicManagerApi(api, session.accessToken)
            .refresh(
              requestId: _requestId(),
              installationId: retained.installationId,
              installationRevision: retained.installationRevision,
              coreRevision: retained.bootstrap!.revision,
            );
        if (!valid() || !identical(account.session, session)) return;
        final selection = await _selectionCache.read(
          ServerMusicSelectionScope.fromSession(session),
          value,
        );
        if (!valid() || !identical(account.session, session)) return;
        final receipt = await _receiptCache.read(
          ServerMusicCommandReceiptScope.fromSession(session),
          value,
          current: valid,
        );
        if (valid() && identical(account.session, session)) {
          _acceptManager(value, isVerified: true);
          lastReceipt = receipt;
          if (selection != null) {
            selectedProviderId = selection.providerId;
            selectedReceiverId = selection.receiverId;
          }
        }
      });
    } catch (error) {
      if (valid()) {
        failure = error is LarenorServerException
            ? error.code
            : 'connection_failed';
      }
    } finally {
      if (!_disposed && epoch == _epoch) {
        busy = false;
        _emit();
      }
    }
  }

  Future<void> selectProvider(String id) async {
    if (busy ||
        !verified ||
        manager?.providers.any((item) => item.setupId == id) != true) {
      return;
    }
    selectedProviderId = id;
    catalog = null;
    selectedMediaUri = null;
    final selectionEpoch = ++_selectionEpoch;
    _emit();
    await _writeSelection(selectionEpoch);
  }

  Future<void> selectReceiver(String id) async {
    if (busy ||
        !verified ||
        manager?.receivers.any(
              (item) => item.id == id && item.available && item.enabled,
            ) !=
            true) {
      return;
    }
    selectedReceiverId = id;
    final selectionEpoch = ++_selectionEpoch;
    _emit();
    await _writeSelection(selectionEpoch);
  }

  Future<void> _writeSelection(int selectionEpoch, {int conflicts = 0}) async {
    final value = manager;
    final provider = selectedProvider;
    final receiver = selectedReceiver;
    final session = account.session;
    final epoch = _epoch;
    if (_disposed ||
        !_authorized ||
        !verified ||
        value == null ||
        provider == null ||
        receiver == null ||
        session == null) {
      return;
    }
    try {
      final scope = ServerMusicSelectionScope.fromSession(session);
      if (_disposed ||
          epoch != _epoch ||
          !_authorized ||
          !verified ||
          !identical(account.session, session) ||
          !identical(manager, value) ||
          !identical(selectedProvider, provider) ||
          !identical(selectedReceiver, receiver) ||
          selectionEpoch != _selectionEpoch) {
        return;
      }
      final written = await _selectionCache.write(
        scope,
        value,
        provider: provider,
        receiver: receiver,
      );
      if (written == null) {
        if (conflicts < 3 &&
            !_disposed &&
            selectionEpoch == _selectionEpoch &&
            epoch == _epoch &&
            _authorized &&
            verified &&
            identical(account.session, session) &&
            identical(manager, value) &&
            identical(selectedProvider, provider) &&
            identical(selectedReceiver, receiver)) {
          await _writeSelection(selectionEpoch, conflicts: conflicts + 1);
        }
        return;
      }
      if (!_disposed &&
          epoch == _epoch &&
          selectionEpoch == _selectionEpoch &&
          _authorized &&
          verified &&
          identical(account.session, session) &&
          identical(manager, value) &&
          identical(selectedProvider, provider) &&
          identical(selectedReceiver, receiver)) {
        return;
      }
      if (!_disposed &&
          _authorized &&
          verified &&
          manager != null &&
          selectedProvider != null &&
          selectedReceiver != null &&
          selectionEpoch != _selectionEpoch) {
        await _writeSelection(_selectionEpoch);
      } else {
        await _selectionCache.clearIfCurrent(written);
      }
    } catch (_) {
      // Selection remains valid in memory; persistence is best effort.
    }
  }

  void selectMedia(String uri) {
    if (busy ||
        !verified ||
        catalog?.items.any((item) => item.uri == uri) != true) {
      return;
    }
    selectedMediaUri = uri;
    _emit();
  }

  Future<void> search(
    String rawQuery, {
    required bool Function() current,
  }) async {
    final value = manager;
    final provider = selectedProvider;
    final query = rawQuery.trim();
    if (_disposed ||
        busy ||
        !_authorized ||
        !current() ||
        !verified ||
        value == null ||
        provider == null ||
        query.isEmpty ||
        query.length > 160 ||
        query.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      return;
    }
    final epoch = _epoch;
    bool valid() =>
        !_disposed &&
        epoch == _epoch &&
        _authorized &&
        current() &&
        verified &&
        identical(manager, value) &&
        identical(selectedProvider, provider);
    busy = true;
    failure = null;
    catalog = null;
    selectedMediaUri = null;
    _emit();
    try {
      await account.withSession((api, session) async {
        final requestId = _requestId();
        final result = await ServerMusicManagerApi(api, session.accessToken)
            .search(
              requestId: requestId,
              manager: value,
              provider: provider,
              query: query,
            );
        if (result.requestId != requestId ||
            result.managerRevision != value.revision ||
            result.items.any(
              (item) => item.providerInstanceId != provider.instanceId,
            )) {
          throw const LarenorServerException('invalid_response');
        }
        if (valid()) catalog = result;
      });
    } catch (error) {
      if (valid()) {
        failure = error is LarenorServerException
            ? error.code
            : 'connection_failed';
      }
    } finally {
      if (!_disposed && epoch == _epoch) {
        busy = false;
        _emit();
      }
    }
  }

  Future<void> loadInProgress({required bool Function() current}) async {
    final value = manager;
    if (_disposed ||
        longformBusy ||
        !_authorized ||
        !_safeCurrent(current) ||
        !verified ||
        value == null) {
      return;
    }
    final epoch = _epoch;
    final longformEpoch = ++_longformEpoch;
    bool valid() =>
        !_disposed &&
        epoch == _epoch &&
        longformEpoch == _longformEpoch &&
        _authorized &&
        _safeCurrent(current) &&
        verified &&
        identical(manager, value);
    longformBusy = true;
    longformFailure = null;
    longform = null;
    _emit();
    try {
      await account.withSession((api, session) async {
        final requestId = _requestId();
        final result = await ServerMusicManagerApi(api, session.accessToken)
            .inProgress(
              requestId: requestId,
              manager: value,
              limit: 25,
              current: valid,
            );
        if (valid() && identical(account.session, session)) {
          longform = result;
        }
      });
    } catch (error) {
      if (valid()) {
        longformFailure = error is LarenorServerException
            ? error.code
            : 'connection_failed';
      }
    } finally {
      if (!_disposed && epoch == _epoch && longformEpoch == _longformEpoch) {
        longformBusy = false;
        _emit();
      }
    }
  }

  Future<void> command(
    ServerMusicOperation operation, {
    double? positionSeconds,
    required bool Function() current,
  }) async {
    final before = manager;
    final receiver = selectedReceiver;
    final media = selectedMedia;
    final needsMedia = {
      ServerMusicOperation.queueAdd,
      ServerMusicOperation.queueReplace,
    }.contains(operation);
    if (_disposed ||
        busy ||
        !_authorized ||
        !current() ||
        !verified ||
        before == null ||
        receiver == null ||
        !receiver.available ||
        !receiver.enabled ||
        !receiver.supports(operation) ||
        (needsMedia && media == null) ||
        (operation == ServerMusicOperation.seek &&
            (positionSeconds == null ||
                !positionSeconds.isFinite ||
                positionSeconds < 0 ||
                positionSeconds > 864000))) {
      return;
    }
    final epoch = _epoch;
    bool valid() =>
        !_disposed &&
        epoch == _epoch &&
        _authorized &&
        current() &&
        verified &&
        identical(manager, before) &&
        identical(selectedReceiver, receiver) &&
        (!needsMedia || identical(selectedMedia, media));
    busy = true;
    failure = null;
    lastReceipt = null;
    _emit();
    try {
      await account.withSession((api, session) async {
        final client = ServerMusicManagerApi(api, session.accessToken);
        final requestId = _requestId();
        final receipt = await client.command(
          requestId: requestId,
          manager: before,
          receiver: receiver,
          operation: operation,
          positionSeconds: positionSeconds,
          mediaUris: needsMedia ? [media!.uri] : const [],
        );
        if (!valid() ||
            receipt.requestId != requestId ||
            receipt.targetId != receiver.id ||
            receipt.operation != operation.wire ||
            !receipt.authenticated) {
          throw const LarenorServerException('effect_unknown');
        }
        final after = await client.read(before.installationId);
        if (!valid() ||
            after.revision != receipt.playerRevision ||
            !_sameAuthority(after, installation!) ||
            !_verifiedEffect(
              operation,
              before,
              after,
              receiver,
              media,
              positionSeconds,
            )) {
          throw const LarenorServerException('effect_unknown');
        }
        _acceptManager(after, isVerified: true);
        bool receiptCurrent() =>
            !_disposed &&
            epoch == _epoch &&
            _authorized &&
            current() &&
            verified &&
            identical(account.session, session) &&
            identical(manager, after) &&
            selectedReceiverId == receipt.targetId;
        try {
          await _receiptCache.write(
            ServerMusicCommandReceiptScope.fromSession(session),
            after,
            receipt,
            current: receiptCurrent,
          );
        } catch (_) {
          // A verified in-memory receipt remains useful; persistence is best effort.
        }
        if (receiptCurrent()) lastReceipt = receipt;
      });
    } catch (error) {
      if (valid()) {
        verified = false;
        failure = error is LarenorServerException
            ? error.code
            : 'connection_failed';
      }
    } finally {
      if (!_disposed && epoch == _epoch) {
        busy = false;
        _emit();
      }
    }
  }

  bool _verifiedEffect(
    ServerMusicOperation operation,
    ServerMusicManager before,
    ServerMusicManager after,
    ServerMusicReceiver expected,
    ServerMusicCatalogItem? media,
    double? position,
  ) {
    final receiver = after.receivers
        .where((item) => item.id == expected.id)
        .firstOrNull;
    if (receiver == null ||
        receiver.provider != expected.provider ||
        receiver.kind != expected.kind ||
        receiver.queueId != expected.queueId ||
        !listEquals(receiver.groupMembers, expected.groupMembers)) {
      return false;
    }
    final oldQueue = before.queueFor(expected);
    final queue = after.queueFor(receiver);
    return switch (operation) {
      ServerMusicOperation.play => receiver.playbackState == 'playing',
      ServerMusicOperation.pause => receiver.playbackState == 'paused',
      ServerMusicOperation.seek =>
        receiver.positionSeconds != null &&
            (receiver.positionSeconds! - position!).abs() <= 2,
      ServerMusicOperation.queueAdd =>
        queue != null && queue.itemCount > (oldQueue?.itemCount ?? 0),
      ServerMusicOperation.queueReplace =>
        queue != null &&
            queue.itemCount == 1 &&
            queue.currentItemUri == media?.uri,
      ServerMusicOperation.queueClear =>
        queue != null && queue.itemCount == 0 && queue.currentItemUri == null,
    };
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    account.removeListener(_accountChanged);
    super.dispose();
  }
}

bool _safeCurrent(bool Function() current) {
  try {
    return current();
  } catch (_) {
    return false;
  }
}
