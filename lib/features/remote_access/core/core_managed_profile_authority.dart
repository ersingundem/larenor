import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../data/remote_profiles.dart';
import '../rdp/rdp_models.dart';
import '../rdp/rdp_security_store.dart';
import '../ssh/ssh_security_store.dart';
import '../vnc/vnc_models.dart';
import '../vnc/vnc_security_store.dart';
import 'core_personal_profiles.dart';
import 'core_personal_profiles_api.dart';

/// A memory-only lease for one exact Core-managed profile. It polls the same
/// authenticated GET used at connect and storage boundaries so server-side
/// profile, account, home or token-family drift retires a live transport.
final class CoreManagedProfileAuthority extends ChangeNotifier {
  CoreManagedProfileAuthority({
    required this.account,
    required this.profile,
    required this.authority,
    required this.ownerCurrent,
    this.refreshInterval = const Duration(seconds: 3),
  }) : _generation = account.generation,
       _session = account.session {
    if (_session == null ||
        _session.context != authority.context ||
        _session.user.id != authority.accountId ||
        _session.sessionFamilyId != authority.sessionFamilyId) {
      _retired = true;
    }
    account.addListener(_accountChanged);
  }

  final ServerAccountController account;
  final CorePersonalProfile profile;
  final CorePersonalProfileAuthority authority;
  final bool Function() ownerCurrent;
  final Duration refreshInterval;
  final int _generation;
  final ServerSession? _session;
  Timer? _timer;
  bool _retired = false, _checking = false, _disposed = false;

  bool get isCurrent {
    try {
      return !_retired &&
          !_disposed &&
          ownerCurrent() &&
          account.isCurrent(_generation) &&
          identical(account.session, _session) &&
          _session?.context == authority.context &&
          _session?.user.id == authority.accountId &&
          _session?.sessionFamilyId == authority.sessionFamilyId;
    } catch (_) {
      return false;
    }
  }

  void _check() {
    if (!isCurrent) {
      retire();
      throw const SshFailure('retired');
    }
  }

  bool _same(RemoteProfile value) =>
      value.id == profile.id &&
      value.name == profile.profile.name &&
      value.protocol == profile.profile.protocol &&
      value.host == profile.profile.host &&
      value.port == profile.profile.port &&
      value.username == profile.profile.username;

  Future<void> validateProfile(
    RemoteProfile value,
    void Function() callerCheck,
  ) async {
    callerCheck();
    _check();
    if (!_same(value)) throw const SshFailure('profile_changed');
    try {
      await account.withSession((api, session) async {
        _check();
        callerCheck();
        if (!identical(session, _session)) {
          throw const LarenorServerException('cancelled');
        }
        final scoped = CorePersonalProfilesApi(
          api,
          session.accessToken,
          authority.context,
          authority.accountId,
          current: () => isCurrent,
        );
        await scoped.verify(profile, authority);
        _check();
        callerCheck();
      });
    } catch (_) {
      retire();
      throw const SshFailure('retired');
    }
  }

  Future<void> validateNow() => validateProfile(profile.profile, _check);

  Future<void> start() async {
    if (_checking || !isCurrent) {
      _check();
      return;
    }
    _checking = true;
    try {
      await validateNow();
      if (isCurrent && _timer == null) {
        _timer = Timer.periodic(refreshInterval, (_) {
          if (_checking || !isCurrent) {
            if (!isCurrent) retire();
            return;
          }
          _checking = true;
          unawaited(
            validateNow().catchError((Object _) {}).whenComplete(() {
              _checking = false;
            }),
          );
        });
      }
    } finally {
      _checking = false;
    }
  }

  SshSecurityStore createSecurityStore() {
    _check();
    return SshSecurityStore(
      namespace: SshSecurityNamespace.coreManaged(
        endpoint: _session!.endpoint.baseUrl,
        coreId: authority.context.coreId,
        homeId: authority.context.homeId,
        accountId: authority.accountId,
        sessionFamilyId: authority.sessionFamilyId,
      ),
      profileValidator: validateProfile,
    );
  }

  RdpSecurityStore createRdpSecurityStore() {
    _check();
    return RdpSecurityStore(
      namespace: RdpSecurityNamespace.coreManaged(
        endpoint: _session!.endpoint.baseUrl,
        coreId: authority.context.coreId,
        homeId: authority.context.homeId,
        accountId: authority.accountId,
        sessionFamilyId: authority.sessionFamilyId,
      ),
      profileValidator: (profile, check) async {
        try {
          await validateProfile(profile, check);
        } on SshFailure catch (error) {
          throw RdpFailure(error.code);
        }
      },
    );
  }

  VncSecurityStore createVncSecurityStore() {
    _check();
    return VncSecurityStore(
      namespace: VncSecurityNamespace.coreManaged(
        endpoint: _session!.endpoint.baseUrl,
        coreId: authority.context.coreId,
        homeId: authority.context.homeId,
        accountId: authority.accountId,
        sessionFamilyId: authority.sessionFamilyId,
      ),
      profileValidator: (profile, check) async {
        try {
          await validateProfile(profile, check);
        } on SshFailure catch (error) {
          throw VncFailure(error.code);
        }
      },
    );
  }

  void _accountChanged() {
    if (!isCurrent) retire();
  }

  void retire() {
    if (_retired) return;
    _retired = true;
    _timer?.cancel();
    _timer = null;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _retired = true;
    _timer?.cancel();
    _timer = null;
    account.removeListener(_accountChanged);
    super.dispose();
  }

  @override
  String toString() => 'CoreManagedProfileAuthority(redacted)';
}
