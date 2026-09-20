import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../health/data/connection_evidence.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../data/remote_profiles.dart';
import 'core_personal_profiles.dart';
import 'core_personal_profiles_api.dart';

enum CoreProfileMutationOutcome { saved, deleted, conflict, uncertain, failed }

/// Memory-only view of account-owned Core metadata. A retained list is visibly
/// stale after an offline/error result and is never mutation authority.
final class CorePersonalProfilesController extends ChangeNotifier {
  CorePersonalProfilesController({
    required this.account,
    required this.windowCurrent,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    account.addListener(_accountChanged);
  }

  final ServerAccountController account;
  final bool Function() windowCurrent;
  final DateTime Function() _clock;
  bool _disposed = false, _visible = false;
  int _epoch = 0;
  int? _boundGeneration;
  ServerContext? _boundContext;
  String? _boundUserId, _boundEndpoint;

  bool busy = false, loaded = false;
  String? failure;
  CoreProfileMutationOutcome? mutationOutcome;
  CorePersonalProfilesSnapshot? snapshot;
  ConnectionEvidence evidence = const ConnectionEvidence.none();

  List<CorePersonalProfile> get profiles => snapshot?.profiles ?? const [];
  bool get canRefresh => _visible && !busy && _readySession != null;
  bool get canMutate =>
      canRefresh && loaded && evidence.isFreshVerified && snapshot != null;

  ServerSession? get _readySession {
    final session = account.session;
    if (!_visible ||
        !windowCurrent() ||
        !account.initialized ||
        account.working ||
        account.hasPendingContext ||
        session == null ||
        session.context == null ||
        session.authMutationPending ||
        session.user.mustChangePassword) {
      return null;
    }
    return session;
  }

  void setVisible(bool value) {
    if (_disposed || _visible == value) return;
    _visible = value;
    if (!value) {
      _retire(clear: true);
    } else {
      unawaited(refresh());
    }
    _emit();
  }

  void _accountChanged() {
    if (_disposed) return;
    final session = _readySession;
    if (session == null || !_sameBinding(session)) {
      _retire(clear: true);
    }
    _emit();
  }

  bool _sameBinding(ServerSession session) =>
      _boundGeneration == null ||
      (_boundGeneration == account.generation &&
          _boundContext == session.context &&
          _boundUserId == session.user.id &&
          _boundEndpoint == session.endpoint.baseUrl);

  void _bind(ServerSession session, int generation) {
    _boundGeneration = generation;
    _boundContext = session.context;
    _boundUserId = session.user.id;
    _boundEndpoint = session.endpoint.baseUrl;
  }

  bool _isCurrent(int operation, int generation, ServerSession original) {
    try {
      final active = _readySession;
      return !_disposed &&
          _visible &&
          operation == _epoch &&
          account.isCurrent(generation) &&
          active != null &&
          active.context == original.context &&
          active.user.id == original.user.id &&
          active.endpoint.baseUrl == original.endpoint.baseUrl;
    } catch (_) {
      return false;
    }
  }

  Future<void> refresh() async {
    final original = _readySession;
    if (original == null || busy) return;
    final previous = snapshot;
    final generation = account.generation;
    final operation = ++_epoch;
    _bind(original, generation);
    busy = true;
    failure = null;
    mutationOutcome = null;
    evidence = snapshot == null
        ? const ConnectionEvidence.connecting()
        : ConnectionEvidence.retrying(
            stage: ConnectionEvidenceStage.verified,
            lastVerifiedAt: evidence.lastVerifiedAt,
          );
    _emit();
    try {
      CorePersonalProfilesSnapshot? result;
      await account.withSession((api, session) async {
        if (!_isCurrent(operation, generation, original)) {
          throw const LarenorServerException('cancelled');
        }
        final scoped = CorePersonalProfilesApi(
          api,
          session.accessToken,
          session.context!,
          current: () => _isCurrent(operation, generation, original),
        );
        result = await scoped.list();
      });
      if (!_isCurrent(operation, generation, original) || result == null) {
        return;
      }
      if (previous != null &&
          (result!.collectionRevision < previous.collectionRevision ||
              result!.collectionRevision == previous.collectionRevision &&
                  !_sameSnapshot(previous, result!))) {
        throw const LarenorServerException('invalid_response');
      }
      snapshot = result;
      loaded = true;
      evidence = ConnectionEvidence.verified(_clock());
    } catch (error) {
      if (_isCurrent(operation, generation, original)) {
        failure = _safeCode(error);
        evidence = _failureEvidence(failure!, evidence.lastVerifiedAt);
        loaded = snapshot != null;
      }
    } finally {
      if (!_disposed && operation == _epoch) {
        busy = false;
        _emit();
      }
    }
  }

  Future<void> create(
    RemoteProfile desired, {
    required bool Function() ownerCurrent,
  }) => _mutate((api) => api.create(desired), ownerCurrent: ownerCurrent);

  Future<void> update(
    CorePersonalProfile target,
    RemoteProfile desired, {
    required bool Function() ownerCurrent,
  }) =>
      _mutate((api) => api.update(target, desired), ownerCurrent: ownerCurrent);

  Future<void> delete(
    CorePersonalProfile target, {
    required bool Function() ownerCurrent,
  }) => _mutate(
    (api) async {
      await api.delete(target);
      return null;
    },
    ownerCurrent: ownerCurrent,
    deleted: target,
  );

  Future<void> _mutate(
    Future<CorePersonalProfile?> Function(CorePersonalProfilesApi) action, {
    required bool Function() ownerCurrent,
    CorePersonalProfile? deleted,
  }) async {
    bool owner() {
      try {
        return ownerCurrent();
      } catch (_) {
        return false;
      }
    }

    final original = _readySession;
    if (!canMutate || original == null || !owner()) return;
    final before = snapshot!;
    final generation = account.generation;
    final operation = ++_epoch;
    busy = true;
    failure = null;
    mutationOutcome = null;
    _emit();
    try {
      CorePersonalProfilesSnapshot? readback;
      CorePersonalProfile? result;
      await account.withSession((api, session) async {
        bool current() =>
            owner() && _isCurrent(operation, generation, original);
        if (!current()) throw const LarenorServerException('cancelled');
        final scoped = CorePersonalProfilesApi(
          api,
          session.accessToken,
          session.context!,
          current: current,
        );
        result = await action(scoped);
        // A write response alone is not current read evidence. Verify the full
        // collection before enabling another mutation.
        readback = await scoped.list();
      });
      if (!_isCurrent(operation, generation, original) ||
          !owner() ||
          readback == null) {
        return;
      }
      final expectedCollectionDelta = deleted != null
          ? 1
          : before.profiles.any((item) => item.id == result?.id)
          ? result!.revision ==
                    before.profiles
                        .singleWhere((item) => item.id == result!.id)
                        .revision
                ? 0
                : 1
          : 1;
      if (before.collectionRevision >
              9223372036854775807 - expectedCollectionDelta ||
          readback!.collectionRevision !=
              before.collectionRevision + expectedCollectionDelta) {
        throw const LarenorServerException('invalid_response');
      }
      if (deleted != null) {
        if (readback!.profiles.any((item) => item.id == deleted.id)) {
          throw const LarenorServerException('invalid_response');
        }
      } else {
        final changed = result;
        if (changed == null ||
            !readback!.profiles.any(
              (item) =>
                  item.id == changed.id &&
                  item.revision == changed.revision &&
                  item.profile.name == changed.profile.name &&
                  item.profile.protocol == changed.profile.protocol &&
                  item.profile.host == changed.profile.host &&
                  item.profile.port == changed.profile.port &&
                  item.profile.username == changed.profile.username,
            )) {
          throw const LarenorServerException('invalid_response');
        }
      }
      snapshot = readback;
      loaded = true;
      evidence = ConnectionEvidence.verified(_clock());
      mutationOutcome = deleted == null
          ? CoreProfileMutationOutcome.saved
          : CoreProfileMutationOutcome.deleted;
    } catch (error) {
      if (_isCurrent(operation, generation, original) && owner()) {
        failure = _safeCode(error);
        final conflict =
            failure == 'revision_conflict' || failure == 'conflict';
        mutationOutcome = conflict
            ? CoreProfileMutationOutcome.conflict
            : {'invalid_request', 'forbidden', 'not_found'}.contains(failure)
            ? CoreProfileMutationOutcome.failed
            : CoreProfileMutationOutcome.uncertain;
        evidence = conflict
            ? ConnectionEvidence.stale(evidence.lastVerifiedAt)
            : _failureEvidence(failure!, evidence.lastVerifiedAt);
        // Preserve the old rows only as a visibly stale, read-only cache.
        loaded = snapshot != null;
      }
    } finally {
      if (!_disposed && operation == _epoch) {
        busy = false;
        _emit();
      }
    }
  }

  ConnectionEvidence _failureEvidence(String code, DateTime? verifiedAt) =>
      switch (code) {
        'connection_failed' ||
        'timeout' ||
        'server_error' => ConnectionEvidence.unavailable(
          stage: verifiedAt == null
              ? ConnectionEvidenceStage.saved
              : ConnectionEvidenceStage.verified,
          lastVerifiedAt: verifiedAt,
        ),
        'unauthorized' ||
        'password_change_required' => ConnectionEvidence.authenticationRequired(
          stage: verifiedAt == null
              ? ConnectionEvidenceStage.reachable
              : ConnectionEvidenceStage.verified,
          lastVerifiedAt: verifiedAt,
        ),
        'forbidden' => ConnectionEvidence.permissionDenied(
          stage: verifiedAt == null
              ? ConnectionEvidenceStage.reachable
              : ConnectionEvidenceStage.verified,
          lastVerifiedAt: verifiedAt,
        ),
        _ => ConnectionEvidence.error(
          stage: verifiedAt == null
              ? ConnectionEvidenceStage.reachable
              : ConnectionEvidenceStage.verified,
          lastVerifiedAt: verifiedAt,
        ),
      };

  String _safeCode(Object error) =>
      error is LarenorServerException ? error.code : 'connection_failed';

  bool _sameSnapshot(
    CorePersonalProfilesSnapshot first,
    CorePersonalProfilesSnapshot second,
  ) {
    if (first.context != second.context ||
        first.profiles.length != second.profiles.length) {
      return false;
    }
    for (var index = 0; index < first.profiles.length; index++) {
      final left = first.profiles[index];
      final right = second.profiles[index];
      final a = left.profile;
      final b = right.profile;
      if (left.id != right.id ||
          left.revision != right.revision ||
          a.name != b.name ||
          a.protocol != b.protocol ||
          a.host != b.host ||
          a.port != b.port ||
          a.username != b.username) {
        return false;
      }
    }
    return true;
  }

  void _retire({required bool clear}) {
    _epoch++;
    busy = false;
    failure = null;
    mutationOutcome = null;
    _boundGeneration = null;
    _boundContext = null;
    _boundUserId = null;
    _boundEndpoint = null;
    if (clear) {
      snapshot = null;
      loaded = false;
      evidence = const ConnectionEvidence.none();
    }
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    account.removeListener(_accountChanged);
    _retire(clear: true);
    _disposed = true;
    super.dispose();
  }

  @override
  String toString() => 'CorePersonalProfilesController(redacted)';
}
