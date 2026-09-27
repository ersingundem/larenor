import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../data/larenor_server_api.dart';
import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../../music_manager/data/server_music_manager_api.dart';
import '../../music_manager/domain/server_music_manager_models.dart';
import '../domain/server_party_dj_models.dart';
import 'server_party_dj_api.dart';
import 'server_party_dj_recovery_store.dart';

final class ServerPartyDjController extends ChangeNotifier {
  ServerPartyDjController(
    this.account, {
    this.installationId,
    String Function()? requestId,
    ServerPartyDjRecoveryStore? recoveryStore,
  }) : _generation = account.generation,
       _requestId = requestId ?? _randomId,
       _recovery = recoveryStore ?? ServerPartyDjRecoveryStore() {
    account.addListener(_accountChanged);
  }

  final ServerAccountController account;
  final String? installationId;
  final int _generation;
  final String Function() _requestId;
  final ServerPartyDjRecoveryStore _recovery;
  int _epoch = 0;
  bool _disposed = false;
  ServerPartyDjRecoveryScope? _recoveryScope;
  ServerPartyDjRecoveryState? _recoveryState;

  bool busy = false;
  String? failure;
  ServerMusicManager? manager;
  ServerMusicProviderBinding? selectedProvider;
  List<ServerMusicCatalogItem> searchResults = const [];
  String? catalogQuery;
  ServerPartyDjRoom? room;
  ServerPartyDjInvitation? invitation;

  bool get canHostLaunch => installationId != null;
  bool get hasPendingEffect => _recoveryState?.pendingEffect != null;

  String? get _activeInstallationId =>
      room?.authority.installationId ?? installationId;

  bool get _authorized =>
      account.isCurrent(_generation) &&
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

  void retire() {
    if (_disposed) return;
    _epoch++;
    busy = false;
    failure = null;
    manager = null;
    selectedProvider = null;
    searchResults = const [];
    catalogQuery = null;
    room = null;
    invitation = null;
    notifyListeners();
  }

  void suspend() {
    if (_disposed) return;
    _epoch++;
    busy = false;
    notifyListeners();
  }

  Future<void> resume({required bool Function() current}) => _run(current, (
    api,
    session,
    valid,
  ) async {
    final scope = ServerPartyDjRecoveryScope.fromSession(session);
    _recoveryScope = scope;
    var recovery = _recoveryState;
    recovery ??= await _recovery.read(scope, current: valid);
    _requireCurrent(valid);
    _recoveryState = recovery;
    ServerPartyDjRoom? recovered;
    ServerPartyDjInvitation? recoveredInvitation;
    var clearRecoveredInvitation = false;
    String? recoveryFailure;
    final pending = recovery?.pendingEffect;
    if (pending != null) {
      try {
        final client = ServerPartyDjApi(api, session, requestId: _requestId);
        if (pending.kind == ServerPartyDjEffectKind.create) {
          final result = await client.executePendingCreate(
            pending,
            current: valid,
          );
          recovered = result.room;
          recoveredInvitation = result.invitation;
        } else {
          recovered = await client.executePendingEffect(
            pending,
            current: valid,
          );
          clearRecoveredInvitation =
              pending.kind == ServerPartyDjEffectKind.join;
        }
      } on LarenorServerException catch (error) {
        if (!_definitive(error.code)) rethrow;
        recoveryFailure = error.code;
        if (pending.kind == ServerPartyDjEffectKind.create ||
            pending.kind == ServerPartyDjEffectKind.join) {
          await _clearRecovery(scope, valid);
          recovery = null;
        } else {
          await _clearPending(scope, recovery!, valid);
          recovery = _recoveryState;
        }
      }
    }
    if (recovered == null && recovery != null) {
      final client = ServerPartyDjApi(api, session, requestId: _requestId);
      final recoveryRoomId = recovery.roomId;
      if (recoveryRoomId == null) {
        throw const LarenorServerException('storage_failed');
      }
      try {
        recovered = await client.read(recoveryRoomId, current: valid);
      } on LarenorServerException catch (error) {
        final rejoin = recovery.invitation;
        if (rejoin != null &&
            (error.code == 'not_found' ||
                error.code == 'party_dj_session_changed')) {
          try {
            recovered = await client.join(rejoin, current: valid);
          } on LarenorServerException catch (rejoinError) {
            if (!_terminalRoomFailure(rejoinError.code)) rethrow;
            recoveryFailure = rejoinError.code;
            await _clearRecovery(scope, valid);
            recovery = null;
          }
        } else if (_terminalRoomFailure(error.code)) {
          recoveryFailure = error.code;
          await _clearRecovery(scope, valid);
          recovery = null;
        } else {
          rethrow;
        }
      }
    }
    if (recovered != null) {
      await _rememberRoom(
        session,
        recovered,
        valid,
        recoveryInvitation: recoveredInvitation ?? recovery?.invitation,
        clearInvitation: clearRecoveredInvitation,
        clearPending: true,
      );
      room = recovered;
      await _loadManager(
        api,
        session.accessToken,
        recovered.authority.installationId,
        valid,
      );
      if (recoveryFailure != null) failure = recoveryFailure;
      return;
    }
    final selectedInstallation = installationId;
    if (selectedInstallation != null) {
      await _loadManager(api, session.accessToken, selectedInstallation, valid);
    }
    if (recoveryFailure != null) failure = recoveryFailure;
  });

  Future<void> loadSetup({required bool Function() current}) => _run(current, (
    api,
    session,
    valid,
  ) async {
    final selectedInstallation = installationId;
    if (selectedInstallation == null) {
      throw const LarenorServerException('invalid_request');
    }
    await _loadManager(api, session.accessToken, selectedInstallation, valid);
  });

  Future<void> retryPending({required bool Function() current}) =>
      resume(current: current);

  void selectProvider(ServerMusicProviderBinding provider) {
    final value = manager;
    if (_disposed ||
        busy ||
        value == null ||
        !value.providers.any((item) => item.setupId == provider.setupId)) {
      return;
    }
    selectedProvider = provider;
    searchResults = const [];
    catalogQuery = null;
    failure = null;
    notifyListeners();
  }

  Future<void> search(String query, {required bool Function() current}) =>
      _run(current, (api, session, valid) async {
        final text = query.trim();
        if (text.isEmpty || text.length > 160) {
          throw const LarenorServerException('invalid_request');
        }
        final selectedInstallation = _activeInstallationId;
        if (selectedInstallation == null) {
          throw const LarenorServerException('music_manager_unavailable');
        }
        var currentManager = await ServerMusicManagerApi(
          api,
          session.accessToken,
        ).read(selectedInstallation);
        _requireCurrent(valid);
        manager = currentManager;
        final retained = selectedProvider;
        final provider = currentManager.providers
            .cast<ServerMusicProviderBinding?>()
            .firstWhere(
              (item) => item?.setupId == retained?.setupId,
              orElse: () => currentManager.providers.firstOrNull,
            );
        if (provider == null) {
          throw const LarenorServerException('music_provider_unavailable');
        }
        selectedProvider = provider;
        final catalog = await ServerMusicManagerApi(api, session.accessToken)
            .search(
              requestId: _requestId(),
              manager: currentManager,
              provider: provider,
              query: text,
            );
        _requireCurrent(valid);
        searchResults = List.unmodifiable(
          catalog.items.where((item) => item.mediaType == 'track'),
        );
        catalogQuery = text;
      });

  Future<void> create(
    ServerMusicReceiver receiver, {
    required bool Function() current,
  }) {
    if (hasPendingEffect) return retryPending(current: current);
    return _run(current, (api, session, valid) async {
      if (!canHostLaunch) {
        throw const LarenorServerException('invalid_request');
      }
      final currentManager = manager;
      if (currentManager == null ||
          currentManager.installationId != installationId) {
        throw const LarenorServerException('music_manager_unavailable');
      }
      if (!receiver.available ||
          !receiver.enabled ||
          !receiver.supports(ServerMusicOperation.queueAdd) ||
          !receiver.capabilities.contains('next_previous') ||
          !currentManager.receivers.any((item) => identical(item, receiver))) {
        throw const LarenorServerException('invalid_request');
      }
      final expiresAt = DateTime.now().toUtc().add(const Duration(hours: 4));
      final pending = ServerPartyDjPendingEffect.create(
        requestId: _requestId(),
        installationId: currentManager.installationId,
        installationRevision: currentManager.installationRevision,
        coreRevision: currentManager.coreRevision,
        managerRevision: currentManager.revision,
        playerRevision: currentManager.revision,
        targetId: receiver.id,
        provider: receiver.provider,
        targetKind: receiver.kind,
        queueId: receiver.queueId,
        groupMembers: receiver.groupMembers,
        expiresAt: expiresAt,
      );
      await _rememberPendingStart(session, pending, expiresAt, valid);
      final client = ServerPartyDjApi(api, session, requestId: _requestId);
      final ServerPartyDjCreateResult result;
      try {
        result = await client.executePendingCreate(pending, current: valid);
      } on LarenorServerException catch (error) {
        if (_definitive(error.code)) {
          final scope =
              _recoveryScope ?? ServerPartyDjRecoveryScope.fromSession(session);
          await _clearRecovery(scope, valid);
        }
        rethrow;
      }
      await _rememberRoom(
        session,
        result.room,
        valid,
        recoveryInvitation: result.invitation,
        clearPending: true,
      );
      room = result.room;
      invitation = result.invitation;
      searchResults = const [];
      catalogQuery = null;
    });
  }

  Future<void> join(
    String invitationValue, {
    required bool Function() current,
  }) {
    if (hasPendingEffect) return retryPending(current: current);
    return _run(current, (api, session, valid) async {
      final parsed = ServerPartyDjInvitation.parse(invitationValue);
      final pending = ServerPartyDjPendingEffect.join(
        invitation: parsed,
        requestId: _requestId(),
      );
      await _rememberPendingStart(
        session,
        pending,
        DateTime.now().toUtc().add(const Duration(days: 1)),
        valid,
      );
      final client = ServerPartyDjApi(api, session, requestId: _requestId);
      final ServerPartyDjRoom joined;
      try {
        joined = await client.executePendingEffect(pending, current: valid);
      } on LarenorServerException catch (error) {
        if (_definitive(error.code)) {
          final scope =
              _recoveryScope ?? ServerPartyDjRecoveryScope.fromSession(session);
          await _clearRecovery(scope, valid);
        }
        rethrow;
      }
      _requireCurrent(valid);
      await _rememberRoom(
        session,
        joined,
        valid,
        clearInvitation: true,
        clearPending: true,
      );
      room = joined;
      invitation = null;
      searchResults = const [];
      catalogQuery = null;
      await _loadManager(
        api,
        session.accessToken,
        joined.authority.installationId,
        valid,
      );
    });
  }

  Future<void> refresh({required bool Function() current}) =>
      _withRoom(current, (client, selected, valid) {
        return client.read(selected.id, current: valid);
      });

  Future<void> heartbeat({required bool Function() current}) =>
      _withRoom(current, (client, selected, valid) {
        return client.heartbeat(selected, current: valid);
      });

  Future<void> propose(
    ServerMusicCatalogItem item, {
    required bool Function() current,
  }) {
    final selected = room;
    if (selected == null) return Future.value();
    if (!selected.canPropose) {
      return _localFailure('party_dj_proposal_limit_reached', current: current);
    }
    final currentManager = manager;
    final verifiedQuery = catalogQuery;
    if (currentManager == null ||
        currentManager.installationId != selected.authority.installationId ||
        verifiedQuery == null) {
      return _localFailure('music_manager_unavailable', current: current);
    }
    final matches = currentManager.providers.where(
      (provider) => provider.instanceId == item.providerInstanceId,
    );
    if (matches.length != 1) {
      return _localFailure('music_provider_unavailable', current: current);
    }
    final provider = matches.single;
    return _dispatchEffect(
      current,
      ServerPartyDjPendingEffect.proposal(
        roomId: selected.id,
        requestId: _requestId(),
        catalogRequestId: _requestId(),
        roomRevision: selected.revision,
        catalogQuery: verifiedQuery,
        mediaUri: item.uri,
        name: item.name,
        providerSetupId: provider.setupId,
        providerRevision: provider.revision,
        providerDomain: provider.domain,
        providerInstanceId: item.providerInstanceId,
      ),
    );
  }

  Future<void> vote(
    ServerPartyDjProposal proposal, {
    required bool Function() current,
  }) => _withRoom(current, (client, selected, valid) {
    return client.vote(
      room: selected,
      proposal: proposal,
      selected: !proposal.votedByCurrentUser,
      current: valid,
    );
  });

  Future<void> decide(
    ServerPartyDjProposal proposal, {
    required bool approve,
    required bool Function() current,
  }) {
    final selected = room;
    if (selected == null) return Future.value();
    if (!selected.isHost) {
      return _localFailure('party_dj_host_required', current: current);
    }
    return _dispatchEffect(
      current,
      ServerPartyDjPendingEffect.decision(
        roomId: selected.id,
        proposalId: proposal.id,
        requestId: _requestId(),
        roomRevision: selected.revision,
        proposalRevision: proposal.revision,
        approve: approve,
        playerRevision: selected.authority.playerRevision,
      ),
    );
  }

  Future<void> dismissProposal(
    ServerPartyDjProposal proposal, {
    required bool Function() current,
  }) => _withRoom(current, (client, selected, valid) {
    if (!selected.isHost ||
        proposal.status != ServerPartyDjProposalStatus.needsAttention) {
      throw const LarenorServerException('party_dj_host_required');
    }
    return client.dismissProposal(
      room: selected,
      proposal: proposal,
      current: valid,
    );
  });

  Future<void> voteToSkip({required bool Function() current}) {
    final selected = room;
    if (selected == null) return Future.value();
    return _dispatchEffect(
      current,
      ServerPartyDjPendingEffect.skip(
        roomId: selected.id,
        requestId: _requestId(),
        roomRevision: selected.revision,
        participantRevision: selected.currentParticipantRevision,
        playerRevision: selected.authority.playerRevision,
      ),
    );
  }

  Future<void> dismissSkip({required bool Function() current}) =>
      _withRoom(current, (client, selected, valid) {
        if (!selected.isHost || !selected.skipNeedsAttention) {
          throw const LarenorServerException('party_dj_host_required');
        }
        return client.dismissSkip(selected, current: valid);
      });

  Future<void> leave({required bool Function() current}) async {
    final selected = room;
    if (selected == null) return;
    await _run(current, (api, session, valid) async {
      await ServerPartyDjApi(
        api,
        session,
        requestId: _requestId,
      ).leave(selected, current: valid);
      final scope =
          _recoveryScope ?? ServerPartyDjRecoveryScope.fromSession(session);
      try {
        await _recovery.clear(scope);
      } finally {
        _recoveryState = null;
        room = null;
        invitation = null;
        searchResults = const [];
        catalogQuery = null;
        if (manager?.installationId != installationId) {
          manager = null;
          selectedProvider = null;
        }
      }
    });
  }

  Future<void> _dispatchEffect(
    bool Function() current,
    ServerPartyDjPendingEffect effect,
  ) => _run(current, (api, session, valid) async {
    final selected = room;
    if (selected == null || selected.id != effect.roomId) {
      throw const LarenorServerException('party_dj_room_changed');
    }
    await _rememberRoom(session, selected, valid, pendingEffect: effect);
    final client = ServerPartyDjApi(api, session, requestId: _requestId);
    final ServerPartyDjRoom value;
    try {
      value = await client.executePendingEffect(effect, current: valid);
    } on LarenorServerException catch (error) {
      if (_definitive(error.code)) {
        final scope =
            _recoveryScope ?? ServerPartyDjRecoveryScope.fromSession(session);
        await _clearPending(scope, _recoveryState!, valid);
      }
      rethrow;
    }
    await _rememberRoom(session, value, valid, clearPending: true);
    room = value;
    _updateVisibleInvitation(value);
  });

  Future<void> _rememberRoom(
    ServerSession session,
    ServerPartyDjRoom value,
    bool Function() valid, {
    ServerPartyDjInvitation? recoveryInvitation,
    ServerPartyDjPendingEffect? pendingEffect,
    bool clearInvitation = false,
    bool clearPending = false,
  }) async {
    final scope =
        _recoveryScope ?? ServerPartyDjRecoveryScope.fromSession(session);
    _recoveryScope = scope;
    final previous = _recoveryState;
    final base = previous != null && previous.roomId == value.id
        ? previous
        : ServerPartyDjRecoveryState(
            roomId: value.id,
            invitation: recoveryInvitation,
            expiresAt: value.expiresAt,
            pendingEffect: null,
          );
    final next = base.copyWith(
      roomRevision: value.revision,
      invitation: recoveryInvitation,
      clearInvitation: clearInvitation,
      pendingEffect: pendingEffect,
      clearPendingEffect: clearPending,
      expiresAt: value.expiresAt,
    );
    await _recovery.write(scope, next, current: valid);
    _requireCurrent(valid);
    _recoveryState = next;
  }

  Future<void> _rememberPendingStart(
    ServerSession session,
    ServerPartyDjPendingEffect pending,
    DateTime expiresAt,
    bool Function() valid,
  ) async {
    final scope = ServerPartyDjRecoveryScope.fromSession(session);
    _recoveryScope = scope;
    final state = ServerPartyDjRecoveryState(
      roomId: pending.roomId,
      invitation: null,
      expiresAt: expiresAt,
      pendingEffect: pending,
    );
    await _recovery.write(scope, state, current: valid);
    _requireCurrent(valid);
    _recoveryState = state;
  }

  Future<void> _clearPending(
    ServerPartyDjRecoveryScope scope,
    ServerPartyDjRecoveryState state,
    bool Function() valid,
  ) async {
    final next = state.copyWith(
      roomRevision: room?.revision ?? state.invitation?.roomRevision ?? 1,
      clearPendingEffect: true,
    );
    await _recovery.write(scope, next, current: valid);
    _requireCurrent(valid);
    _recoveryState = next;
  }

  Future<void> _clearRecovery(
    ServerPartyDjRecoveryScope scope,
    bool Function() valid,
  ) async {
    await _recovery.clear(scope);
    _requireCurrent(valid);
    _recoveryState = null;
    room = null;
    invitation = null;
    searchResults = const [];
    catalogQuery = null;
  }

  void _updateVisibleInvitation(ServerPartyDjRoom value) {
    final retained = invitation;
    if (retained != null && retained.roomId == value.id) {
      invitation = ServerPartyDjInvitation(
        roomId: retained.roomId,
        roomRevision: value.revision,
        inviteCode: retained.inviteCode,
      );
    }
  }

  Future<void> _localFailure(String code, {required bool Function() current}) =>
      _run(current, (_, _, _) async {
        throw LarenorServerException(code);
      });

  static bool _definitive(String code) =>
      code != 'retired' &&
      code != 'connection_failed' &&
      code != 'invalid_response' &&
      code != 'storage_failed';

  static bool _terminalRoomFailure(String code) =>
      code == 'not_found' ||
      code == 'party_dj_room_closed' ||
      code == 'party_dj_room_expired' ||
      code == 'party_dj_authority_changed' ||
      code == 'party_dj_session_changed';

  Future<void> _loadManager(
    LarenorServerApi api,
    String token,
    String selectedInstallation,
    bool Function() valid,
  ) async {
    final value = await ServerMusicManagerApi(
      api,
      token,
    ).read(selectedInstallation);
    _requireCurrent(valid);
    manager = value;
    if (selectedProvider == null ||
        !value.providers.any(
          (provider) => provider.setupId == selectedProvider!.setupId,
        )) {
      selectedProvider = value.providers.firstOrNull;
      searchResults = const [];
      catalogQuery = null;
    }
  }

  Future<void> _withRoom(
    bool Function() current,
    Future<ServerPartyDjRoom> Function(
      ServerPartyDjApi client,
      ServerPartyDjRoom selected,
      bool Function() valid,
    )
    action,
  ) {
    final selected = room;
    if (selected == null) return Future.value();
    return _run(current, (api, session, valid) async {
      final value = await action(
        ServerPartyDjApi(api, session, requestId: _requestId),
        selected,
        valid,
      );
      await _rememberRoom(session, value, valid);
      room = value;
      _updateVisibleInvitation(value);
    });
  }

  Future<void> _run(
    bool Function() current,
    Future<void> Function(
      LarenorServerApi api,
      ServerSession session,
      bool Function() valid,
    )
    action,
  ) async {
    bool routeCurrent() {
      try {
        return current();
      } catch (_) {
        return false;
      }
    }

    if (_disposed || busy || !_authorized || !routeCurrent()) return;
    final operation = ++_epoch;
    bool valid() =>
        !_disposed && operation == _epoch && _authorized && routeCurrent();
    busy = true;
    failure = null;
    notifyListeners();
    try {
      await account.withSession((api, session) async {
        await action(
          api,
          session,
          () => valid() && identical(account.session, session),
        );
        _requireCurrent(() => valid() && identical(account.session, session));
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

  static void _requireCurrent(bool Function() valid) {
    if (!valid()) throw const LarenorServerException('retired');
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _epoch++;
    account.removeListener(_accountChanged);
    super.dispose();
  }

  static String _randomId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}
