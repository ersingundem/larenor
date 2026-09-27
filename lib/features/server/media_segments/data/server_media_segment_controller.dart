// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';

import '../../data/larenor_server_api.dart';
import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../../media_catalog/data/server_media_catalog_api.dart';
import '../domain/server_media_segment_models.dart';
import 'server_media_segment_api.dart';

final class ServerMediaSegmentController extends ChangeNotifier {
  ServerMediaSegmentController(this.account, {String Function()? requestId})
    : _accountGeneration = account.generation,
      _requestId = requestId {
    account.addListener(_accountChanged);
  }

  final ServerAccountController account;
  final int _accountGeneration;
  final String Function()? _requestId;
  int _epoch = 0;
  bool _disposed = false;

  bool busy = false;
  String? failure;
  ServerMediaSegmentResult? result;

  bool get _authorized =>
      account.isCurrent(_accountGeneration) &&
      account.initialized &&
      !account.working &&
      !account.hasPendingContext &&
      account.session?.context != null &&
      account.session?.sessionFamilyId != null &&
      account.session?.authMutationPending == false &&
      account.session?.user.mustChangePassword == false;

  void _accountChanged() {
    if (!_authorized) retire();
  }

  bool _route(bool Function() current) {
    try {
      return current();
    } catch (_) {
      return false;
    }
  }

  void retire() {
    if (_disposed) return;
    _epoch++;
    busy = false;
    failure = null;
    result = null;
    notifyListeners();
  }

  Future<void> load(
    ServerMediaSegmentSource source, {
    required int sourceEpoch,
    required int itemEpoch,
    required bool Function() current,
  }) => _load(
    sourceEpoch: sourceEpoch,
    itemEpoch: itemEpoch,
    current: current,
    read: (api, session, requestCurrent) => ServerMediaSegmentApi(
      api,
      session,
      requestId: _requestId,
    ).read(source, sourceEpoch: sourceEpoch, itemEpoch: itemEpoch),
  );

  /// Resolves [itemId] through Core's current catalog and immediately reads
  /// its segment markers using the returned exact revisions. Every await is
  /// guarded by the owning player route; there is no retry or direct fallback.
  Future<void> loadCurrentItem(
    String itemId, {
    required int sourceEpoch,
    required int itemEpoch,
    required bool Function() current,
  }) {
    late final String normalizedItemId;
    try {
      normalizedItemId = serverMediaSegmentItemId(itemId);
    } on LarenorServerException {
      if (!_disposed && _route(current)) {
        _epoch++;
        busy = false;
        result = null;
        failure = 'invalid_request';
        notifyListeners();
      }
      return Future.value();
    }
    return _load(
      sourceEpoch: sourceEpoch,
      itemEpoch: itemEpoch,
      current: current,
      read: (api, session, requestCurrent) async {
        final catalog = ServerMediaCatalogApi(
          api,
          session.accessToken,
          requestId: _requestId,
        );
        final target = await catalog.discoverTarget(current: requestCurrent);
        if (!requestCurrent()) {
          throw const LarenorServerException('retired');
        }
        final page = await catalog.resolveVerifiedTarget(
          target: target,
          itemId: normalizedItemId,
          current: requestCurrent,
        );
        if (!requestCurrent()) {
          throw const LarenorServerException('retired');
        }
        final item = page.items.single;
        final source = ServerMediaSegmentSource.fromCatalog(page, item);
        final value = await ServerMediaSegmentApi(
          api,
          session,
          requestId: _requestId,
        ).read(source, sourceEpoch: sourceEpoch, itemEpoch: itemEpoch);
        if (!requestCurrent()) {
          throw const LarenorServerException('retired');
        }
        return value;
      },
    );
  }

  Future<void> _load({
    required int sourceEpoch,
    required int itemEpoch,
    required bool Function() current,
    required Future<ServerMediaSegmentResult> Function(
      LarenorServerApi api,
      ServerSession session,
      bool Function() requestCurrent,
    )
    read,
  }) async {
    if (_disposed || busy || !_authorized || !_route(current)) return;
    final operation = ++_epoch;
    bool valid() =>
        !_disposed && operation == _epoch && _authorized && _route(current);
    busy = true;
    failure = null;
    result = null;
    notifyListeners();
    try {
      await account.withSession((api, session) async {
        bool requestCurrent() => valid() && identical(account.session, session);
        final value = await read(api, session, requestCurrent);
        if (valid() &&
            identical(account.session, session) &&
            value.isCurrent(sourceEpoch: sourceEpoch, itemEpoch: itemEpoch)) {
          result = value;
        }
      });
    } on LarenorServerException catch (error) {
      if (valid()) failure = error.code;
    } catch (_) {
      if (valid()) failure = 'connection_failed';
    } finally {
      if (!_disposed && operation == _epoch) {
        busy = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _epoch++;
    account.removeListener(_accountChanged);
    super.dispose();
  }
}
