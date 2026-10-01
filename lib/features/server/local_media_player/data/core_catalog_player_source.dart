// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../../offline_media/data/server_offline_media_controller.dart';
import 'core_catalog_playback_capability_adapter.dart';
import '../domain/core_catalog_player_binding.dart';

enum CoreCatalogPlayerSourceMode { coreLease, offlineVault }

final class CoreCatalogPlayerLease {
  CoreCatalogPlayerLease({
    required this.playable,
    required this.mode,
    required Future<void> Function() close,
    Future<String>? invalidated,
  }) : invalidated = invalidated ?? Completer<String>().future,
       _close = close;

  final Playable playable;
  final CoreCatalogPlayerSourceMode mode;
  final Future<String> invalidated;
  final Future<void> Function() _close;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _close();
  }
}

abstract base class CoreCatalogPlayerSourcePort {
  Future<CoreCatalogPlayerLease?> open(
    CoreCatalogPlayerBinding binding, {
    required CoreCatalogPlayerSourceMode mode,
    required CoreCatalogPlaybackAuthorization? authorization,
    required bool Function() current,
  });
  void retire();
  void dispose() => retire();
}

typedef CoreCatalogPlayerSourceFactory = CoreCatalogPlayerSourcePort Function(
  ServerAccountController account,
);

final coreCatalogPlayerSourceFactoryProvider =
    Provider<CoreCatalogPlayerSourceFactory>(
      (_) =>
          (account) => CoreCatalogPlayerSources(account),
    );

// Verified-Core catalog screens may offer the online source. Actual admission
// still fails closed unless the native profile and provider observation are
// current and Core consumes that exact one-use observation for the lease.
final coreCatalogOnlinePlaybackAvailableProvider = Provider<bool>((_) => true);

final class CoreCatalogPlayerSources extends CoreCatalogPlayerSourcePort {
  CoreCatalogPlayerSources(ServerAccountController account)
    : _online = CoreLeaseCatalogPlayerSource(account),
      _offline = OfflineVaultCoreCatalogPlayerSource(account);
  final CoreLeaseCatalogPlayerSource _online;
  final OfflineVaultCoreCatalogPlayerSource _offline;

  @override
  Future<CoreCatalogPlayerLease?> open(
    CoreCatalogPlayerBinding binding, {
    required CoreCatalogPlayerSourceMode mode,
    required CoreCatalogPlaybackAuthorization? authorization,
    required bool Function() current,
  }) {
    switch (mode) {
      case CoreCatalogPlayerSourceMode.coreLease:
        if (authorization == null) return Future.value(null);
        _offline.retire();
        return _online.open(
          binding,
          mode: mode,
          authorization: authorization,
          current: current,
        );
      case CoreCatalogPlayerSourceMode.offlineVault:
        if (authorization != null) return Future.value(null);
        _online.retire();
        return _offline.open(
          binding,
          mode: mode,
          authorization: null,
          current: current,
        );
    }
  }

  @override
  void retire() {
    _online.retire();
    _offline.retire();
  }

  @override
  void dispose() {
    _online.dispose();
    _offline.dispose();
  }
}

final class _OnlineLease {
  const _OnlineLease({
    required this.id,
    required this.revision,
    required this.expiresAt,
  });
  final String id;
  final int revision;
  final DateTime expiresAt;
}

final class _OnlineLeaseOwner {
  _OnlineLeaseOwner({
    required this.generation,
    required this.accountGeneration,
    required this.binding,
    required this.authorization,
    required this.session,
    required this.current,
    required this.selected,
    required this.invalidated,
  });

  final int generation;
  final int accountGeneration;
  final CoreCatalogPlayerBinding binding;
  final CoreCatalogPlaybackAuthorization authorization;
  final ServerSession session;
  final bool Function() current;
  _OnlineLease selected;
  final Completer<String> invalidated;
  CoreCatalogPlayerLease? lease;
  Timer? renewal;
  Timer? expiry;
}

/// A short-lived Core HTTP source. Provider URLs and keys never cross this
/// adapter; media_kit receives only the current Core URL and bearer header.
final class CoreLeaseCatalogPlayerSource extends CoreCatalogPlayerSourcePort {
  CoreLeaseCatalogPlayerSource(
    this._account, {
    CoreCatalogPlaybackCapabilityAdapter? capability,
    Random? random,
    DateTime Function()? clock,
  }) : _capability =
           capability ?? CoreCatalogPlaybackCapabilityAdapter(_account),
       _random = random ?? Random.secure(),
       _clock = clock ?? (() => DateTime.now().toUtc()) {
    _account.addListener(_accountChanged);
  }

  final ServerAccountController _account;
  final CoreCatalogPlaybackCapabilityAdapter _capability;
  final Random _random;
  final DateTime Function() _clock;
  int _generation = 0;
  bool _disposed = false;
  _OnlineLeaseOwner? _active;

  String _requestId() => List.generate(
    32,
    (_) => _random.nextInt(16).toRadixString(16),
    growable: false,
  ).join();
  Never _invalid() => throw const LarenorServerException('invalid_response');
  String _id(Object? value) {
    if (value is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
      _invalid();
    }
    return value;
  }

  int _revision(Object? value) {
    if (value is! int || value < 1 || value > 0x7ffffffffffffffe) {
      _invalid();
    }
    return value;
  }

  _OnlineLease _parse(
    Object? raw,
    CoreCatalogPlayerBinding binding,
    ServerSession session,
  ) {
    final envelope = serverObject(raw);
    if (envelope.length != 1 || !envelope.containsKey('lease')) _invalid();
    final value = serverObject(envelope['lease']);
    const keys = {
      'schemaVersion',
      'leaseId',
      'revision',
      'authority',
      'title',
      'mediaKind',
      'runtimeSeconds',
      'contentLength',
      'contentType',
      'byteIntegrity',
      'supportsByteRanges',
      'state',
      'expiresAt',
      'restartBehavior',
    };
    if (value.length != keys.length ||
        !value.keys.every(keys.contains) ||
        value['schemaVersion'] != 1 ||
        value['title'] != binding.title ||
        value['mediaKind'] != binding.kind.name ||
        value['runtimeSeconds'] != binding.runtimeSeconds ||
        value['contentLength'] is! int ||
        (value['contentLength'] as int) < 1 ||
        value['contentType'] != 'application/octet-stream' ||
        value['byteIntegrity'] != 'source_bound' ||
        value['supportsByteRanges'] != true ||
        value['state'] != 'active' ||
        value['restartBehavior'] != 'terminal_invalid') {
      _invalid();
    }
    final authority = serverObject(value['authority']);
    const authorityKeys = {
      'schemaVersion',
      'coreId',
      'homeId',
      'accountId',
      'accountRevision',
      'sessionFamilyId',
      'installationId',
      'installationRevision',
      'snapshotRevision',
      'jellyfinServiceRevision',
      'itemId',
      'mediaKey',
    };
    final context = session.context;
    if (context == null ||
        session.sessionFamilyId == null ||
        authority.length != authorityKeys.length ||
        !authority.keys.every(authorityKeys.contains) ||
        authority['schemaVersion'] != 1 ||
        authority['coreId'] != context.coreId ||
        authority['homeId'] != context.homeId ||
        authority['accountId'] != session.user.id ||
        authority['sessionFamilyId'] != session.sessionFamilyId ||
        authority['installationId'] != binding.installationId ||
        authority['installationRevision'] != binding.installationRevision ||
        authority['snapshotRevision'] != binding.snapshotRevision ||
        authority['jellyfinServiceRevision'] !=
            binding.jellyfinServiceRevision ||
        authority['itemId'] != binding.itemId ||
        authority['mediaKey'] != binding.mediaKey) {
      _invalid();
    }
    _revision(authority['accountRevision']);
    final expiresAt = value['expiresAt'];
    if (expiresAt is! int || expiresAt < 1 || expiresAt > 253402300799) {
      _invalid();
    }
    return _OnlineLease(
      id: _id(value['leaseId']),
      revision: _revision(value['revision']),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        expiresAt * 1000,
        isUtc: true,
      ),
    );
  }

  void _cancelTimers(_OnlineLeaseOwner owner) {
    owner.renewal?.cancel();
    owner.renewal = null;
    owner.expiry?.cancel();
    owner.expiry = null;
  }

  void _detach(_OnlineLeaseOwner owner, {String? reason}) {
    _cancelTimers(owner);
    if (reason != null && !owner.invalidated.isCompleted) {
      owner.invalidated.complete(reason);
    }
    if (identical(_active, owner)) _active = null;
  }

  bool _ownerCurrent(_OnlineLeaseOwner owner) =>
      !_disposed &&
      identical(_active, owner) &&
      owner.generation == _generation &&
      owner.current() &&
      _account.isCurrent(owner.accountGeneration) &&
      identical(_account.session, owner.session);

  void _invalidate(_OnlineLeaseOwner owner, String reason) {
    if (!identical(_active, owner)) return;
    _detach(owner, reason: reason);
    final lease = owner.lease;
    if (lease != null) unawaited(lease.close());
  }

  void _accountChanged() {
    final owner = _active;
    if (owner == null) return;
    if (!_account.isCurrent(owner.accountGeneration) ||
        !identical(_account.session, owner.session)) {
      _invalidate(owner, 'lease_unavailable');
    }
  }

  Future<void> _renew(_OnlineLeaseOwner owner) async {
    if (!_ownerCurrent(owner)) {
      _invalidate(owner, 'lease_unavailable');
      return;
    }
    final previous = owner.selected;
    final expectedRevision = previous.revision + 1;
    if (expectedRevision > 0x7ffffffffffffffe) {
      _invalidate(owner, 'lease_unavailable');
      return;
    }
    final exactRenewed = _OnlineLease(
      id: previous.id,
      revision: expectedRevision,
      expiresAt: previous.expiresAt,
    );
    var requestStarted = false;
    try {
      final before = await _capability.capture();
      if (!_ownerCurrent(owner) ||
          before == null ||
          !owner.authorization.profile.sameFacts(before)) {
        _invalidate(owner, 'lease_unavailable');
        return;
      }
      final renewed = await _account.withSession((api, session) async {
        if (!identical(session, owner.session) || !_ownerCurrent(owner)) {
          throw const LarenorServerException('retired');
        }
        requestStarted = true;
        return _parse(
          await api.request(
            'POST',
            '/media/offline/playback-leases/${previous.id}/renew',
            token: session.accessToken,
            body: {
              'schemaVersion': 1,
              'requestId': _requestId(),
              'expectedRevision': previous.revision,
            },
          ),
          owner.binding,
          session,
        );
      });
      if (renewed.id != exactRenewed.id ||
          renewed.revision != exactRenewed.revision) {
        owner.selected = exactRenewed;
        await _retireRemote(owner.session, exactRenewed);
        _invalidate(owner, 'lease_unavailable');
        return;
      }
      if (!_ownerCurrent(owner)) {
        await _retireRemote(owner.session, renewed);
        return;
      }
      final after = await _capability.capture();
      if (!_ownerCurrent(owner) ||
          after == null ||
          !owner.authorization.profile.sameFacts(after)) {
        owner.selected = renewed;
        await _retireRemote(owner.session, renewed);
        _invalidate(owner, 'lease_unavailable');
        return;
      }
      if (!_schedule(owner, renewed)) {
        owner.selected = renewed;
        await _retireRemote(owner.session, renewed);
        _invalidate(owner, 'lease_unavailable');
      }
    } on LarenorServerException catch (_) {
      if (requestStarted) {
        owner.selected = exactRenewed;
        await _retireRemote(owner.session, exactRenewed);
      }
      _invalidate(owner, 'lease_unavailable');
    } catch (_) {
      if (requestStarted) {
        owner.selected = exactRenewed;
        await _retireRemote(owner.session, exactRenewed);
      }
      _invalidate(owner, 'lease_unavailable');
    }
  }

  bool _schedule(_OnlineLeaseOwner owner, _OnlineLease selected) {
    _cancelTimers(owner);
    final remaining = selected.expiresAt.difference(_clock().toUtc());
    if (remaining <= Duration.zero) return false;
    owner.selected = selected;
    final delay = remaining > const Duration(seconds: 45)
        ? const Duration(seconds: 45)
        : Duration(milliseconds: max(1, remaining.inMilliseconds ~/ 2));
    owner.renewal = Timer(delay, () => unawaited(_renew(owner)));
    owner.expiry = Timer(
      remaining,
      () => _invalidate(owner, 'lease_unavailable'),
    );
    return true;
  }

  @override
  Future<CoreCatalogPlayerLease?> open(
    CoreCatalogPlayerBinding binding, {
    required CoreCatalogPlayerSourceMode mode,
    required CoreCatalogPlaybackAuthorization? authorization,
    required bool Function() current,
  }) async {
    if (_disposed ||
        mode != CoreCatalogPlayerSourceMode.coreLease ||
        authorization == null ||
        !current()) {
      return null;
    }
    final generation = ++_generation;
    final previous = _active;
    if (previous != null) {
      _detach(previous, reason: 'retired');
      await previous.lease?.close();
    }
    bool valid() => !_disposed && generation == _generation && current();
    if (!valid()) return null;
    final accountGeneration = _account.generation;
    final capturedSession = _account.session;
    if (capturedSession == null ||
        !await _capability.revalidate(authorization, current: valid) ||
        !valid() ||
        !_account.isCurrent(accountGeneration) ||
        !identical(_account.session, capturedSession)) {
      return null;
    }
    final requestId = _requestId();
    final exactCreated = _OnlineLease(
      id: requestId,
      revision: 1,
      expiresAt: _clock().toUtc(),
    );
    var requestStarted = false;
    _OnlineLease? created;
    try {
      created = await _account.withSession((api, session) async {
        if (!identical(session, capturedSession) || !valid()) {
          throw const LarenorServerException('retired');
        }
        requestStarted = true;
        return _parse(
          await api.request(
            'POST',
            '/media/offline/playback-leases',
            token: session.accessToken,
            body: {
              'schemaVersion': 1,
              'requestId': requestId,
              'installationId': binding.installationId,
              'expectedInstallationRevision': binding.installationRevision,
              'expectedSnapshotRevision': binding.snapshotRevision,
              'expectedJellyfinServiceRevision':
                  binding.jellyfinServiceRevision,
              'itemId': binding.itemId,
              'mediaKey': binding.mediaKey,
              'playbackObservationId': authorization.observationId,
            },
          ),
          binding,
          session,
        );
      });
      final selected = created;
      if (selected == null) _invalid();
      if (selected.id != exactCreated.id ||
          selected.revision != exactCreated.revision) {
        await _retireRemote(capturedSession, exactCreated);
        return null;
      }
      if (!valid() ||
          !_account.isCurrent(accountGeneration) ||
          !identical(_account.session, capturedSession) ||
          !await _capability.revalidate(authorization, current: valid)) {
        await _retireRemote(capturedSession, selected);
        return null;
      }
      final invalidated = Completer<String>();
      late final _OnlineLeaseOwner owner;
      late final CoreCatalogPlayerLease lease;
      owner = _OnlineLeaseOwner(
        generation: generation,
        accountGeneration: accountGeneration,
        binding: binding,
        authorization: authorization,
        session: capturedSession,
        current: current,
        selected: selected,
        invalidated: invalidated,
      );
      lease = CoreCatalogPlayerLease(
        playable: Media(
          capturedSession.endpoint
              .api('/media/offline/playback-leases/${selected.id}/content')
              .toString(),
          httpHeaders: {
            'Authorization': 'Bearer ${capturedSession.accessToken}',
          },
        ),
        mode: mode,
        invalidated: invalidated.future,
        close: () async {
          _detach(owner);
          await _retireRemote(owner.session, owner.selected);
        },
      );
      owner.lease = lease;
      if (!_schedule(owner, selected) || !valid()) {
        await lease.close();
        return null;
      }
      _active = owner;
      if (!_ownerCurrent(owner)) {
        _invalidate(owner, 'lease_unavailable');
        return null;
      }
      return lease;
    } catch (_) {
      if (requestStarted) await _retireRemote(capturedSession, exactCreated);
      return null;
    }
  }

  Future<void> _retireRemote(
    ServerSession captured,
    _OnlineLease selected,
  ) async {
    try {
      await _account.withSession((api, session) async {
        if (!identical(session, captured)) return;
        await api.request(
          'POST',
          '/media/offline/playback-leases/${selected.id}/retire',
          token: session.accessToken,
          body: {
            'schemaVersion': 1,
            'requestId': _requestId(),
            'expectedRevision': selected.revision,
          },
        );
      });
    } catch (_) {
      // The short lease remains bounded and is never redispatched here.
    }
  }

  @override
  void retire() {
    if (_disposed) return;
    _generation++;
    final active = _active;
    if (active == null) return;
    _detach(active, reason: 'retired');
    final lease = active.lease;
    if (lease != null) unawaited(lease.close());
  }

  @override
  void dispose() {
    if (_disposed) return;
    retire();
    _account.removeListener(_accountChanged);
    _disposed = true;
  }
}

/// Explicit fallback: download into the encrypted vault, verify the returned
/// authority, then expose only the vault loopback. It is not streaming.
final class OfflineVaultCoreCatalogPlayerSource
    extends CoreCatalogPlayerSourcePort {
  OfflineVaultCoreCatalogPlayerSource(
    ServerAccountController account, {
    ServerOfflineMediaController? offline,
  }) : _offline = offline ?? ServerOfflineMediaController(account);
  final ServerOfflineMediaController _offline;
  int _generation = 0;
  bool _disposed = false;

  @override
  Future<CoreCatalogPlayerLease?> open(
    CoreCatalogPlayerBinding binding, {
    required CoreCatalogPlayerSourceMode mode,
    required CoreCatalogPlaybackAuthorization? authorization,
    required bool Function() current,
  }) async {
    if (_disposed ||
        mode != CoreCatalogPlayerSourceMode.offlineVault ||
        authorization != null ||
        !current()) {
      return null;
    }
    final generation = ++_generation;
    bool valid() => !_disposed && generation == _generation && current();
    final restored = await _offline.loadCompletedItem(
      binding.itemId,
      current: valid,
    );
    if (!valid()) return null;
    if (!restored) {
      // Absence is the only state that may contact Core. Vault integrity,
      // key, or scope failures must never be overwritten by a redownload.
      if (_offline.failure != null) return null;
      await _offline.downloadCurrentItem(binding.itemId, current: valid);
    }
    final manifest = _offline.manifest;
    if (!valid() ||
        manifest == null ||
        !binding.acceptsOfflineManifest(manifest)) {
      if (manifest != null && !binding.acceptsOfflineManifest(manifest)) {
        _offline.retire(purge: true);
      }
      return null;
    }
    final uri = await _offline.openPlayback(current: valid);
    if (!valid() || uri == null) {
      await _offline.closePlayback();
      return null;
    }
    return CoreCatalogPlayerLease(
      playable: Media(uri.toString()),
      mode: mode,
      close: _offline.closePlayback,
    );
  }

  @override
  void retire() {
    if (_disposed) return;
    _generation++;
    _offline.retire();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _offline.dispose();
  }
}
