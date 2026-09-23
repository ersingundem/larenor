// ignore_for_file: prefer_initializing_formals

import 'dart:math';

import '../../../media/music/domain/music_models.dart';
import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../domain/server_music_manager_models.dart';
import 'server_music_manager_api.dart';
import 'server_music_selection_cache.dart';

/// Secret-free description of one verified legacy Direct music player.
final class LegacyMusicPlayerPreview {
  const LegacyMusicPlayerPreview._(this.name);

  final String name;
  bool get requiresExplicitCoreSelection => true;

  @override
  String toString() => 'Legacy music player preview';
}

/// One-session authority to map one exact Direct player to an explicitly
/// selected central provider and receiver.
final class LegacyMusicPlayerMappingReceipt {
  const LegacyMusicPlayerMappingReceipt._(this.preview);

  final LegacyMusicPlayerPreview preview;

  @override
  String toString() => 'Legacy music player mapping';
}

final class _LegacyPlayerSnapshot {
  const _LegacyPlayerSnapshot({
    required this.accountGeneration,
    required this.entityId,
    required this.configEntryId,
    required this.name,
    required this.registryId,
    required this.deviceId,
  });

  final Object accountGeneration;
  final String entityId, configEntryId, name, registryId;
  final String? deviceId;
}

final class _MappingState {
  _MappingState(this.source);

  final _LegacyPlayerSnapshot source;
  bool inFlight = false, consumed = false;
  String? selectedCorePair;
}

final class _CoreSelection {
  const _CoreSelection({
    required this.session,
    required this.manager,
    required this.provider,
    required this.receiver,
  });

  final ServerSession session;
  final ServerMusicManager manager;
  final ServerMusicProviderBinding provider;
  final ServerMusicReceiver receiver;
}

/// Requires an explicit, live Core provider/player choice before persisting a
/// replacement for one fresh Direct Music Assistant player selection.
final class LegacyMusicPlayerMapping {
  LegacyMusicPlayerMapping({
    required ServerAccountController account,
    required Future<MusicDiscovery> Function() loadLegacyDiscovery,
    ServerMusicSelectionCache? selectionCache,
    DateTime Function()? now,
    String Function()? requestId,
  }) : _account = account,
       _accountGeneration = account.generation,
       _loadLegacyDiscovery = loadLegacyDiscovery,
       _selectionCache = selectionCache ?? ServerMusicSelectionCache(),
       _now = now ?? DateTime.now,
       _requestId = requestId ?? _randomId {
    account.addListener(_accountChanged);
  }

  final ServerAccountController _account;
  final int _accountGeneration;
  final Future<MusicDiscovery> Function() _loadLegacyDiscovery;
  final ServerMusicSelectionCache _selectionCache;
  final DateTime Function() _now;
  final String Function() _requestId;
  final Expando<_MappingState> _states = Expando();
  bool _retired = false;

  static const maximumPreviewTargets = 256;

  static bool canPreview(MusicQueueTarget target) => _safeTargetShape(target);

  static String _randomId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  bool get _authorized =>
      !_retired &&
      _account.isCurrent(_accountGeneration) &&
      _account.initialized &&
      !_account.working &&
      !_account.hasPendingContext &&
      _account.session?.user.canAdminister == true &&
      _account.session?.authMutationPending == false &&
      _account.session?.user.mustChangePassword == false;

  void _accountChanged() {
    if (!_authorized) _retire();
  }

  void _retire() {
    if (_retired) return;
    _retired = true;
    _account.removeListener(_accountChanged);
  }

  void dispose() => _retire();

  bool _routeCurrent(bool Function() current) {
    try {
      return current();
    } catch (_) {
      return false;
    }
  }

  void _check(bool Function() current) {
    if (_authorized && _routeCurrent(current)) return;
    throw StateError('Legacy music player scope changed');
  }

  void _checkReceipt(
    LegacyMusicPlayerMappingReceipt receipt,
    _MappingState state,
    String corePair,
    bool Function() current,
  ) {
    _check(current);
    if (!identical(_states[receipt], state) ||
        state.consumed ||
        !state.inFlight ||
        state.selectedCorePair != corePair) {
      throw StateError('Legacy music player confirmation expired');
    }
  }

  Future<LegacyMusicPlayerMappingReceipt?> prepare(
    MusicQueueTarget selected, {
    required bool Function() current,
  }) async {
    _check(current);
    final discovery = await _loadLegacyDiscovery();
    _check(current);
    final source = _snapshot(discovery, selected, _now().toUtc());
    if (source == null) return null;
    final receipt = LegacyMusicPlayerMappingReceipt._(
      LegacyMusicPlayerPreview._(source.name),
    );
    _states[receipt] = _MappingState(source);
    return receipt;
  }

  Future<void> confirm(
    LegacyMusicPlayerMappingReceipt receipt, {
    required ServerMusicManager manager,
    required ServerMusicProviderBinding provider,
    required ServerMusicReceiver receiver,
    required bool Function() current,
  }) async {
    _check(current);
    final state = _states[receipt];
    if (state == null || state.consumed) {
      throw StateError('Legacy music player confirmation expired');
    }
    if (state.inFlight) {
      throw StateError('Legacy music player confirmation in progress');
    }
    final corePair = _corePair(manager, provider, receiver);
    state
      ..inFlight = true
      ..selectedCorePair = corePair;
    String? written;
    try {
      _checkReceipt(receipt, state, corePair, current);
      final latest = await _loadLegacyDiscovery();
      _checkReceipt(receipt, state, corePair, current);
      final source = _snapshotFor(latest, state.source, _now().toUtc());
      if (source == null || !_sameLegacy(source, state.source)) {
        throw StateError('Legacy music player changed');
      }
      final selection = await _refreshCore(
        receipt,
        state,
        corePair,
        manager,
        provider,
        receiver,
        current,
      );
      _checkReceipt(receipt, state, corePair, current);
      written = await _selectionCache.write(
        ServerMusicSelectionScope.fromSession(selection.session),
        selection.manager,
        provider: selection.provider,
        receiver: selection.receiver,
      );
      if (written == null) {
        throw StateError('Core music selection changed');
      }
      if (!_authorized ||
          !_routeCurrent(current) ||
          !identical(_states[receipt], state) ||
          state.selectedCorePair != corePair ||
          !identical(_account.session, selection.session)) {
        await _selectionCache.clearIfCurrent(written);
        throw StateError('Legacy music player scope changed');
      }
      final restored = await _selectionCache.read(
        ServerMusicSelectionScope.fromSession(selection.session),
        selection.manager,
      );
      _checkReceipt(receipt, state, corePair, current);
      if (!identical(_account.session, selection.session) ||
          restored?.providerId != selection.provider.setupId ||
          restored?.receiverId != selection.receiver.id) {
        await _selectionCache.clearIfCurrent(written);
        throw StateError('Core music selection changed');
      }
      state
        ..consumed = true
        ..inFlight = false;
      _states[receipt] = null;
    } catch (_) {
      if (written != null &&
          (!_authorized ||
              !_routeCurrent(current) ||
              !identical(_states[receipt], state))) {
        await _selectionCache.clearIfCurrent(written);
      }
      rethrow;
    } finally {
      if (identical(_states[receipt], state) && !state.consumed) {
        state
          ..inFlight = false
          ..selectedCorePair = null;
      }
    }
  }

  Future<_CoreSelection> _refreshCore(
    LegacyMusicPlayerMappingReceipt receipt,
    _MappingState state,
    String corePair,
    ServerMusicManager manager,
    ServerMusicProviderBinding provider,
    ServerMusicReceiver receiver,
    bool Function() current,
  ) async {
    _checkReceipt(receipt, state, corePair, current);
    final selection = await _account.withSession((api, session) async {
      _checkReceipt(receipt, state, corePair, current);
      final refreshed = await ServerMusicManagerApi(api, session.accessToken)
          .refresh(
            requestId: _requestId(),
            installationId: manager.installationId,
            installationRevision: manager.installationRevision,
            coreRevision: manager.coreRevision,
          );
      _checkReceipt(receipt, state, corePair, current);
      if (!identical(_account.session, session) ||
          refreshed.installationId != manager.installationId ||
          refreshed.installationRevision != manager.installationRevision ||
          refreshed.coreRevision != manager.coreRevision ||
          refreshed.revision < manager.revision) {
        throw StateError('Core music manager changed');
      }
      final freshProvider = refreshed.providers
          .where((item) => _sameProvider(item, provider))
          .firstOrNull;
      final freshReceiver = refreshed.receivers
          .where(
            (item) =>
                _sameReceiver(item, receiver) && item.available && item.enabled,
          )
          .firstOrNull;
      if (freshProvider == null || freshReceiver == null) {
        throw StateError('Core music selection changed');
      }
      return _CoreSelection(
        session: session,
        manager: refreshed,
        provider: freshProvider,
        receiver: freshReceiver,
      );
    });
    _checkReceipt(receipt, state, corePair, current);
    if (!identical(_account.session, selection.session)) {
      throw StateError('Legacy music player scope changed');
    }
    return selection;
  }
}

_LegacyPlayerSnapshot? _snapshot(
  MusicDiscovery discovery,
  MusicQueueTarget selected,
  DateTime now,
) {
  final matches = discovery.queueTargets
      .where(
        (item) =>
            item.entityId == selected.entityId &&
            item.configEntryId == selected.configEntryId,
      )
      .toList(growable: false);
  if (matches.length != 1 || !_sameTarget(matches.single, selected)) {
    return null;
  }
  return _snapshotForTarget(discovery, matches.single, now);
}

_LegacyPlayerSnapshot? _snapshotFor(
  MusicDiscovery discovery,
  _LegacyPlayerSnapshot expected,
  DateTime now,
) {
  final matches = discovery.queueTargets
      .where(
        (item) =>
            item.entityId == expected.entityId &&
            item.configEntryId == expected.configEntryId,
      )
      .toList(growable: false);
  if (matches.length != 1) return null;
  return _snapshotForTarget(discovery, matches.single, now);
}

_LegacyPlayerSnapshot? _snapshotForTarget(
  MusicDiscovery discovery,
  MusicQueueTarget target,
  DateTime now,
) {
  if (!discovery.configured ||
      !discovery.freshAt(now) ||
      const {
        MusicDiscoverySource.inventory,
        MusicDiscoverySource.configEntries,
        MusicDiscoverySource.registry,
      }.any(discovery.issues.containsKey) ||
      !discovery.entries.any(
        (entry) => entry.id == target.configEntryId && entry.isLoaded,
      ) ||
      !_safeTargetShape(target)) {
    return null;
  }
  return _LegacyPlayerSnapshot(
    accountGeneration: discovery.accountGeneration,
    entityId: target.entityId,
    configEntryId: target.configEntryId,
    name: target.name,
    registryId: target.registryId!,
    deviceId: target.deviceId,
  );
}

bool _safeTargetShape(MusicQueueTarget target) =>
    target.available &&
    target.enabled &&
    target.registryId != null &&
    _entity(target.entityId) &&
    _binding(target.configEntryId, 128) &&
    _binding(target.registryId!, 128) &&
    (target.deviceId == null || _binding(target.deviceId!, 128)) &&
    _name(target.name);

bool _entity(String value) =>
    value.length <= 128 &&
    RegExp(r'^media_player\.[a-z0-9_]+$').hasMatch(value);

bool _binding(String value, int maximum) =>
    value.isNotEmpty &&
    value.length <= maximum &&
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:\-]*$').hasMatch(value);

bool _name(String value) =>
    value.isNotEmpty &&
    value.length <= 160 &&
    value == value.trim() &&
    !value.contains(
      RegExp(r'[\x00-\x1f\x7f\u200e\u200f\u202a-\u202e\u2066-\u2069\ufeff]'),
    );

bool _sameTarget(MusicQueueTarget left, MusicQueueTarget right) =>
    left.entityId == right.entityId &&
    left.configEntryId == right.configEntryId &&
    left.name == right.name &&
    left.registryId == right.registryId &&
    left.deviceId == right.deviceId &&
    left.available == right.available &&
    left.enabled == right.enabled;

bool _sameLegacy(_LegacyPlayerSnapshot left, _LegacyPlayerSnapshot right) =>
    identical(left.accountGeneration, right.accountGeneration) &&
    left.entityId == right.entityId &&
    left.configEntryId == right.configEntryId &&
    left.name == right.name &&
    left.registryId == right.registryId &&
    left.deviceId == right.deviceId;

String _corePair(
  ServerMusicManager manager,
  ServerMusicProviderBinding provider,
  ServerMusicReceiver receiver,
) =>
    '${manager.installationId}:${manager.installationRevision}:'
    '${manager.coreRevision}:${provider.setupId}:${provider.revision}:'
    '${provider.domain}:${provider.instanceId}:${receiver.id}:'
    '${receiver.provider}:${receiver.kind}:${receiver.queueId ?? ''}:'
    '${receiver.groupMembers.join(',')}';

bool _sameProvider(
  ServerMusicProviderBinding left,
  ServerMusicProviderBinding right,
) =>
    left.setupId == right.setupId &&
    left.revision == right.revision &&
    left.domain == right.domain &&
    left.instanceId == right.instanceId;

bool _sameReceiver(ServerMusicReceiver left, ServerMusicReceiver right) =>
    left.id == right.id &&
    left.provider == right.provider &&
    left.kind == right.kind &&
    left.queueId == right.queueId &&
    _sameStrings(left.groupMembers, right.groupMembers);

bool _sameStrings(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
