// ignore_for_file: prefer_initializing_formals

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../../core/direct_credential_record.dart';
import '../../../../core/direct_home_access.dart';
import '../../../../shared/network/server_bound_client.dart';
import '../../../server/data/server_account_controller.dart';
import '../../../server/services/data/server_services_api.dart';
import '../../../server/services/domain/server_service_models.dart';

enum LegacyMediaProvider { jellyfin }

/// A secret-free prompt model for an old direct provider connection.
final class LegacyJellyfinProviderPreview {
  const LegacyJellyfinProviderPreview._();

  LegacyMediaProvider get provider => LegacyMediaProvider.jellyfin;

  /// Direct credentials are never copied into a Core provider mapping.
  bool get requiresCredentialReentry => true;

  @override
  String toString() => 'Legacy media provider preview';
}

/// A one-session explicit confirmation opportunity for an exact legacy tuple.
final class LegacyJellyfinProviderMigrationReceipt {
  const LegacyJellyfinProviderMigrationReceipt._();

  LegacyMediaProvider get provider => LegacyMediaProvider.jellyfin;
  bool get requiresCredentialReentry => true;

  @override
  String toString() => 'Legacy media provider migration';
}

final class _LegacyJellyfinProviderSnapshot {
  const _LegacyJellyfinProviderSnapshot({
    required this.fields,
    required this.preview,
  });

  final Map<String, String> fields;
  final LegacyJellyfinProviderPreview preview;
}

/// Reads only enough old secure state to offer an explicit transition.
///
/// The complete credential tuple is validated for presence, but no field is
/// returned. Pending or uncertain direct writes remain fail-closed in
/// [DirectCredentialRecord].
final class LegacyJellyfinProviderPreviewReader {
  LegacyJellyfinProviderPreviewReader({
    FlutterSecureStorage? storage,
    DirectHomeAccess? access,
  }) : _access = access,
       _record = DirectCredentialRecord(
         service: DirectCredentialService.jellyfin,
         storage: storage,
         access: access,
       );

  final DirectHomeAccess? _access;
  final DirectCredentialRecord _record;

  void _check(bool Function() isCurrent) {
    _access?.check();
    try {
      if (isCurrent()) return;
    } catch (_) {
      // A throwing route/preview guard is a denial.
    }
    throw StateError('Legacy media provider scope changed');
  }

  Future<LegacyJellyfinProviderPreview?> read({
    required bool Function() isCurrent,
  }) async => (await _readSnapshot(isCurrent: isCurrent))?.preview;

  Future<_LegacyJellyfinProviderSnapshot?> _readSnapshot({
    required bool Function() isCurrent,
  }) async {
    _check(isCurrent);
    final fields = await _record.readFields();
    _check(isCurrent);
    final baseUrl = fields['baseUrl'];
    final userId = fields['userId'];
    final accessToken = fields['accessToken'];
    if (baseUrl == null ||
        baseUrl.isEmpty ||
        baseUrl.length > 2048 ||
        userId == null ||
        userId.isEmpty ||
        userId.length > 256 ||
        userId.contains(RegExp(r'[\x00-\x1F\x7F]')) ||
        accessToken == null ||
        accessToken.isEmpty ||
        accessToken.length > 4096 ||
        accessToken.contains(RegExp(r'[\x00-\x1F\x7F]'))) {
      return null;
    }
    try {
      parseServerUrl(baseUrl);
    } on FormatException {
      return null;
    }
    _check(isCurrent);
    return _LegacyJellyfinProviderSnapshot(
      fields: Map.unmodifiable({
        'baseUrl': baseUrl,
        'userId': userId,
        'accessToken': accessToken,
      }),
      preview: const LegacyJellyfinProviderPreview._(),
    );
  }
}

final class _CoreJellyfinBaseline {
  const _CoreJellyfinBaseline(this.revision, this.checkedAt);
  final int revision;
  final DateTime? checkedAt;
}

final class _LegacyJellyfinProviderMigrationState {
  _LegacyJellyfinProviderMigrationState({
    required this.source,
    required this.baseline,
  });

  final _LegacyJellyfinProviderSnapshot source;
  final Map<String, _CoreJellyfinBaseline> baseline;
  bool inFlight = false;
  bool consumed = false;
  String? selectedTargetId;
  int? selectedTargetRevision;
  String? verifiedTargetId;
  int? verifiedTargetRevision;
}

/// Moves authority to a newly entered and freshly authenticated Core service,
/// then retires the old device-local credential tuple without copying it.
abstract interface class LegacyJellyfinProviderMigrationGateway {
  Future<LegacyJellyfinProviderMigrationReceipt?> prepare({
    required bool Function() isCurrent,
  });

  Future<void> confirm(
    LegacyJellyfinProviderMigrationReceipt receipt,
    ServerService target, {
    required bool Function() isCurrent,
  });

  void dispose();
}

final class LegacyJellyfinProviderMigration
    implements LegacyJellyfinProviderMigrationGateway {
  LegacyJellyfinProviderMigration({
    required ServerAccountController account,
    FlutterSecureStorage? storage,
    DirectHomeAccess? access,
  }) : _account = account,
       _accountGeneration = account.generation,
       _reader = LegacyJellyfinProviderPreviewReader(
         storage: storage,
         access: access,
       ) {
    account.addListener(_accountChanged);
  }

  final ServerAccountController _account;
  final int _accountGeneration;
  final LegacyJellyfinProviderPreviewReader _reader;
  final Expando<_LegacyJellyfinProviderMigrationState> _states = Expando();
  bool _retired = false;

  bool get _authorized =>
      !_retired &&
      _account.isCurrent(_accountGeneration) &&
      _account.initialized &&
      !_account.working &&
      _account.session?.user.canAdminister == true;

  void _accountChanged() {
    if (!_authorized) _retire();
  }

  void _retire() {
    if (_retired) return;
    _retired = true;
    _account.removeListener(_accountChanged);
  }

  @override
  void dispose() => _retire();

  void _check(bool Function() isCurrent) {
    try {
      if (_authorized && isCurrent()) return;
    } catch (_) {
      // A throwing route/confirmation guard is a denial.
    }
    throw StateError('Legacy media provider scope changed');
  }

  bool _stillCurrent(bool Function() isCurrent) {
    try {
      return _authorized && isCurrent();
    } catch (_) {
      return false;
    }
  }

  void _checkReceipt(
    LegacyJellyfinProviderMigrationReceipt receipt,
    _LegacyJellyfinProviderMigrationState state,
    ServerService target,
    bool Function() isCurrent,
  ) {
    _check(isCurrent);
    if (!identical(_states[receipt], state) ||
        state.consumed ||
        !state.inFlight ||
        state.selectedTargetId != target.id ||
        state.selectedTargetRevision != target.revision) {
      throw StateError('Legacy media provider confirmation expired');
    }
  }

  Future<List<ServerService>> _services(bool Function() isCurrent) async {
    _check(isCurrent);
    final result = await _account.withSession((api, session) async {
      _check(isCurrent);
      final services = await ServerServicesApi(api, session.accessToken).list();
      _check(isCurrent);
      if (!identical(_account.session, session)) {
        throw StateError('Legacy media provider scope changed');
      }
      return services;
    });
    _check(isCurrent);
    return result;
  }

  @override
  Future<LegacyJellyfinProviderMigrationReceipt?> prepare({
    required bool Function() isCurrent,
  }) async {
    _check(isCurrent);
    final source = await _reader._readSnapshot(isCurrent: isCurrent);
    _check(isCurrent);
    if (source == null) return null;
    final services = await _services(isCurrent);
    final receipt = LegacyJellyfinProviderMigrationReceipt._();
    _states[receipt] = _LegacyJellyfinProviderMigrationState(
      source: source,
      baseline: Map.unmodifiable({
        for (final service in services)
          if (service.kind == ServerServiceKind.jellyfin)
            service.id: _CoreJellyfinBaseline(
              service.revision,
              service.verification.checkedAt,
            ),
      }),
    );
    return receipt;
  }

  @override
  Future<void> confirm(
    LegacyJellyfinProviderMigrationReceipt receipt,
    ServerService target, {
    required bool Function() isCurrent,
  }) async {
    _check(isCurrent);
    final state = _states[receipt];
    if (state == null || state.consumed) {
      throw StateError('Legacy media provider confirmation expired');
    }
    if (state.inFlight) {
      throw StateError('Legacy media provider confirmation in progress');
    }
    final retry = state.verifiedTargetId != null;
    if (retry &&
        (target.id != state.verifiedTargetId ||
            target.revision != state.verifiedTargetRevision)) {
      throw StateError('Core media provider changed');
    }
    state
      ..inFlight = true
      ..selectedTargetId = target.id
      ..selectedTargetRevision = target.revision;
    try {
      _checkReceipt(receipt, state, target, isCurrent);
      if (!retry) {
        final current = await _reader._readSnapshot(isCurrent: isCurrent);
        _checkReceipt(receipt, state, target, isCurrent);
        if (current == null ||
            !_sameFields(current.fields, state.source.fields)) {
          throw StateError('Legacy media provider changed');
        }
      }
      final services = await _services(isCurrent);
      _checkReceipt(receipt, state, target, isCurrent);
      final candidate = services
          .where(
            (service) =>
                service.id == target.id && service.revision == target.revision,
          )
          .firstOrNull;
      if (candidate == null ||
          !_sameService(candidate, target) ||
          !_acceptableCoreTarget(candidate, state, retry: retry)) {
        throw StateError('Core media provider is not freshly authenticated');
      }
      state.verifiedTargetId = candidate.id;
      state.verifiedTargetRevision = candidate.revision;
      await _reader._record.clear(
        isCurrent: () =>
            _stillCurrent(isCurrent) &&
            identical(_states[receipt], state) &&
            !state.consumed &&
            state.inFlight &&
            state.selectedTargetId == target.id &&
            state.selectedTargetRevision == target.revision,
      );
      _checkReceipt(receipt, state, target, isCurrent);
      state.consumed = true;
      state.inFlight = false;
      _states[receipt] = null;
    } finally {
      if (identical(_states[receipt], state) && !state.consumed) {
        state.inFlight = false;
        if (state.verifiedTargetId == null) {
          state.selectedTargetId = null;
          state.selectedTargetRevision = null;
        }
      }
    }
  }

  bool _acceptableCoreTarget(
    ServerService candidate,
    _LegacyJellyfinProviderMigrationState state, {
    required bool retry,
  }) {
    if (candidate.kind != ServerServiceKind.jellyfin ||
        candidate.verification.state !=
            ServerServiceVerificationState.authenticated ||
        candidate.verification.checkedAt == null ||
        candidate.credentialKeys.length != 1 ||
        !const {'token', 'apiKey'}.contains(candidate.credentialKeys.single)) {
      return false;
    }
    if (retry) {
      return candidate.id == state.verifiedTargetId &&
          candidate.revision == state.verifiedTargetRevision;
    }
    final previous = state.baseline[candidate.id];
    return previous == null ||
        (candidate.revision > previous.revision &&
            candidate.verification.checkedAt != previous.checkedAt);
  }
}

bool _sameFields(Map<String, String> left, Map<String, String> right) =>
    left.length == right.length &&
    left.entries.every((entry) => right[entry.key] == entry.value);

bool _sameService(ServerService left, ServerService right) =>
    left.id == right.id &&
    left.name == right.name &&
    left.kind == right.kind &&
    left.baseUrl == right.baseUrl &&
    left.revision == right.revision &&
    _sameStrings(left.credentialKeys, right.credentialKeys) &&
    left.verification.state == right.verification.state &&
    left.verification.checkedAt == right.verification.checkedAt &&
    left.verification.version == right.verification.version;

bool _sameStrings(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
