import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../data/server_account_controller.dart';
import '../../domain/server_local_media_scope.dart';
import '../../domain/server_models.dart';
import '../../media_catalog/data/server_media_catalog_api.dart';
import '../../media_segments/domain/server_media_segment_models.dart';
import '../domain/server_offline_media_models.dart';
import 'server_offline_media_api.dart';
import 'server_offline_media_vault.dart';

final class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

final class ServerOfflineMediaController extends ChangeNotifier {
  ServerOfflineMediaController(this.account, {ServerOfflineMediaVault? vault})
    : _accountGeneration = account.generation,
      _scope = _scopeFrom(account.session),
      _localMediaScope = null,
      vault = vault ?? ServerOfflineMediaVault() {
    account.addListener(_accountChanged);
  }

  ServerOfflineMediaController.local(
    this.account,
    ServerLocalMediaScope scope, {
    ServerOfflineMediaVault? vault,
  }) : _accountGeneration = account.generation,
       _scope = _scopeFromLocal(scope),
       _localMediaScope = scope,
       vault = vault ?? ServerOfflineMediaVault() {
    account.addListener(_accountChanged);
  }

  final ServerAccountController account;
  final ServerOfflineMediaVault vault;
  final int _accountGeneration;
  final ServerOfflineMediaScope? _scope;
  final ServerLocalMediaScope? _localMediaScope;
  int _epoch = 0;
  bool _disposed = false;
  ServerOfflineMediaPlaybackLease? _playbackLease;

  bool busy = false;
  String? failure;
  ServerOfflineMediaManifest? manifest;

  static ServerOfflineMediaScope? _scopeFrom(ServerSession? session) {
    if (session?.context == null || session?.sessionFamilyId == null) {
      return null;
    }
    try {
      return ServerOfflineMediaScope.fromSession(session!);
    } catch (_) {
      return null;
    }
  }

  static ServerOfflineMediaScope _scopeFromLocal(ServerLocalMediaScope scope) =>
      ServerOfflineMediaScope(
        coreId: scope.coreId,
        homeId: scope.homeId,
        accountId: scope.accountId,
        sessionFamilyId: scope.sessionFamilyId,
      );

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
    final local = _localMediaScope;
    if (local != null) {
      final current = account.localMediaScope;
      if (current == local) return;
      final authoritativeRetirement =
          !account.working &&
          !account.hasPendingContext &&
          (current != null || account.initialized);
      retire(purge: authoritativeRetirement);
      return;
    }
    if (_authorized) return;
    final currentScope = _scopeFrom(account.session);
    final retired = switch ((_scope, currentScope)) {
      (final ServerOfflineMediaScope expected, final actual?) =>
        !expected.sameAuthority(actual),
      (final ServerOfflineMediaScope _, null) =>
        account.initialized && !account.working && !account.hasPendingContext,
      _ => false,
    };
    retire(purge: retired);
  }

  bool _currentManifest(ServerOfflineMediaManifest selected) {
    final session = account.session;
    final context = session?.context;
    return _authorized &&
        context != null &&
        session?.sessionFamilyId == selected.sessionFamilyId &&
        session?.user.id == selected.accountId &&
        context.coreId == selected.coreId &&
        context.homeId == selected.homeId;
  }

  Future<void> closePlayback() async {
    final retained = _playbackLease;
    _playbackLease = null;
    await retained?.close();
  }

  Future<void> _purgeRetired(
    ServerOfflineMediaManifest? retained,
    ServerOfflineMediaScope? scope,
  ) async {
    if (retained != null) await vault.purge(retained.grantId);
    if (scope != null) await vault.purgeScope(scope);
  }

  Future<Uri?> openPlayback({required bool Function() current}) async {
    final selected = manifest;
    if (_disposed ||
        busy ||
        selected == null ||
        !selected.complete ||
        !_currentManifest(selected) ||
        !current()) {
      return null;
    }
    failure = null;
    try {
      await closePlayback();
      if (_disposed || !_currentManifest(selected) || !current()) return null;
      final lease = await vault.openPlayback(selected);
      if (_disposed || !_currentManifest(selected) || !current()) {
        await lease.close();
        return null;
      }
      _playbackLease = lease;
      return lease.uri;
    } catch (_) {
      if (!_disposed && current()) {
        failure = 'offline_media_integrity_failed';
        notifyListeners();
      }
      return null;
    }
  }

  Future<bool> loadCompletedItem(
    String itemId, {
    required bool Function() current,
  }) async {
    if (_disposed || busy || !_authorized || !current()) return false;
    final scope = _scope;
    final session = account.session;
    if (scope == null || session == null) return false;
    final normalizedItemId = serverMediaSegmentItemId(itemId);
    final operation = ++_epoch;
    bool valid() =>
        !_disposed &&
        operation == _epoch &&
        _authorized &&
        identical(account.session, session) &&
        current();
    busy = true;
    failure = null;
    notifyListeners();
    try {
      final selected = await vault.loadCompletedItem(scope, normalizedItemId);
      if (!valid() || selected == null) return false;
      manifest = selected;
      notifyListeners();
      return true;
    } catch (_) {
      if (valid()) {
        failure = 'offline_media_integrity_failed';
        notifyListeners();
      }
      return false;
    } finally {
      if (!_disposed && operation == _epoch) {
        busy = false;
        notifyListeners();
      }
    }
  }

  bool _currentLocalScope(
    ServerLocalMediaScope scope,
    bool Function() current,
  ) {
    try {
      return !_disposed &&
          _localMediaScope == scope &&
          account.localMediaScope == scope &&
          current();
    } catch (_) {
      return false;
    }
  }

  Future<List<ServerOfflineMediaManifest>> completedForLocalScope(
    ServerLocalMediaScope scope, {
    required bool Function() current,
  }) async {
    if (!_currentLocalScope(scope, current)) return const [];
    final operation = ++_epoch;
    final completed = await vault.completed(_scopeFromLocal(scope));
    if (_disposed ||
        operation != _epoch ||
        !_currentLocalScope(scope, current)) {
      return const [];
    }
    return completed;
  }

  Future<Uri?> openCompletedForLocalScope(
    ServerLocalMediaScope scope,
    ServerOfflineMediaManifest selected, {
    required bool Function() current,
  }) async {
    final expected = _scopeFromLocal(scope);
    if (!expected.matches(selected) ||
        !_currentLocalScope(scope, current)) {
      return null;
    }
    final operation = ++_epoch;
    await closePlayback();
    if (_disposed ||
        operation != _epoch ||
        !_currentLocalScope(scope, current)) {
      return null;
    }
    final lease = await vault.openPlayback(selected);
    if (_disposed ||
        operation != _epoch ||
        !_currentLocalScope(scope, current)) {
      await lease.close();
      return null;
    }
    _playbackLease = lease;
    return lease.uri;
  }

  Future<void> purgeLocalScope(ServerLocalMediaScope scope) async {
    if (_localMediaScope != scope) {
      throw const FormatException('Invalid offline scope');
    }
    await closePlayback();
    await vault.purgeScope(_scopeFromLocal(scope));
  }

  void retire({bool purge = false}) {
    if (_disposed) return;
    _epoch++;
    unawaited(closePlayback());
    final retained = manifest;
    busy = false;
    failure = null;
    manifest = null;
    if (purge) {
      final scope = _scope;
      unawaited(_purgeRetired(retained, scope));
    }
    notifyListeners();
  }

  Future<void> downloadCurrentItem(
    String itemId, {
    required bool Function() current,
  }) async {
    if (_disposed || busy || !_authorized || !current()) return;
    final operation = ++_epoch;
    bool valid() =>
        !_disposed && operation == _epoch && _authorized && current();
    busy = true;
    failure = null;
    notifyListeners();
    try {
      await account.withSession((api, session) async {
        final normalizedItemId = serverMediaSegmentItemId(itemId);
        var selected = manifest;
        final offline = ServerOfflineMediaApi(api, session);
        if (selected == null || selected.itemId != normalizedItemId) {
          final catalog = ServerMediaCatalogApi(api, session.accessToken);
          final target = await catalog.discoverTarget(current: valid);
          final page = await catalog.resolveVerifiedTarget(
            target: target,
            itemId: normalizedItemId,
            current: valid,
          );
          final used = await vault.usedBytes();
          if (!valid()) throw const LarenorServerException('retired');
          selected = await offline.create(
            page,
            page.items.single,
            availableBytes: ServerOfflineMediaVault.quotaBytes - used,
            quotaBytes: ServerOfflineMediaVault.quotaBytes,
          );
          if (valid()) manifest = selected;
        }
        final granted = selected;
        var currentManifest = granted;
        final sink = _DigestSink();
        final digest = sha256.startChunkedConversion(sink);
        var retainedBytes = 0;
        await for (final chunk in vault.streamChunks(currentManifest.grantId)) {
          digest.add(chunk);
          retainedBytes += chunk.length;
        }
        if (retainedBytes != currentManifest.downloadedBytes) {
          throw const LarenorServerException('offline_media_integrity_failed');
        }
        while (valid() && !currentManifest.complete) {
          final offset = currentManifest.downloadedBytes;
          final chunk = await offline.chunk(currentManifest);
          if (!valid()) return;
          await vault.writeChunk(currentManifest.grantId, offset, chunk);
          digest.add(chunk);
          final next = offset + chunk.length;
          final finalChunk = next == currentManifest.contentLength;
          if (next > currentManifest.contentLength) {
            throw const LarenorServerException('invalid_response');
          }
          if (finalChunk) digest.close();
          currentManifest = await offline.progress(
            currentManifest,
            next,
            sha256: finalChunk ? sink.value?.toString() : null,
          );
          if (currentManifest.complete) {
            await vault.storeCompletedManifest(currentManifest);
          }
          if (valid() && identical(account.session, session)) {
            manifest = currentManifest;
            notifyListeners();
          }
        }
      });
    } on LarenorServerException catch (error) {
      if (valid() && error.code != 'retired') failure = error.code;
    } catch (_) {
      if (valid()) failure = 'connection_failed';
    } finally {
      if (!_disposed && operation == _epoch) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<void> cancel({required bool Function() current}) async {
    final selected = manifest;
    if (_disposed || selected == null) return;
    final operation = ++_epoch;
    busy = true;
    await closePlayback();
    notifyListeners();
    try {
      if (_authorized) {
        await account.withSession((api, session) async {
          await ServerOfflineMediaApi(api, session).revoke(selected);
        });
      }
    } catch (_) {
      // Local access is removed even when Core is currently unreachable.
    } finally {
      await vault.purge(selected.grantId);
      if (!_disposed && operation == _epoch && current()) {
        manifest = null;
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
    unawaited(closePlayback());
    account.removeListener(_accountChanged);
    super.dispose();
  }
}
