import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/connection_evidence_status.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../server/providers/server_providers.dart';
import '../core/core_personal_profiles.dart';
import '../core/core_personal_profiles_controller.dart';
import '../core/core_managed_profile_authority.dart';
import '../data/remote_profiles.dart';
import '../rdp/rdp_models.dart';
import '../rdp/rdp_schema6_controller.dart';
import '../rdp/rdp_schema6_models.dart';
import '../rdp/rdp_schema6_security_store.dart';
import '../rdp/rdp_security_store.dart';
import '../rdp/rdp_session_panel.dart';
import '../ssh/sftp_browser_panel.dart';
import '../ssh/ssh_security_store.dart';
import '../ssh/ssh_terminal_panel.dart';
import '../ssh/ssh_tunnel_panel.dart';
import '../vnc/vnc_models.dart';
import '../vnc/vnc_security_store.dart';
import '../vnc/vnc_session_panel.dart';
import 'personal_session_boundary.dart';

enum _LocalCleanupPhase { retrying, failed }

enum _GatewayEnrollmentPhase {
  idle,
  inspectingGateway,
  gatewayObserved,
  inspectingTarget,
  targetObserved,
  saving,
  failed,
}

final class _PendingLocalCleanup {
  _PendingLocalCleanup({required this.authority, required this.erase});

  final CoreManagedProfileAuthority authority;
  final Future<void> Function(bool Function() current) erase;
  _LocalCleanupPhase phase = _LocalCleanupPhase.retrying;
}

final class _PendingGatewaySecretCleanup {
  _PendingGatewaySecretCleanup({
    required this.profileId,
    required this.cleanup,
    required this.closeEditorOnSuccess,
  });

  final String profileId;
  final RdpSchema6OwnedSecretCleanup cleanup;
  final bool closeEditorOnSuccess;
  bool retrying = false;
}

class CorePersonalProfilesScreen extends ConsumerStatefulWidget {
  const CorePersonalProfilesScreen({
    super.key,
    required this.isCurrent,
    required this.onBack,
    this.onRdpMicrophonePermissionPromptChanged,
    this.onRdpFileTransferPickerChanged,
  });

  final bool Function() isCurrent;
  final VoidCallback onBack;
  final ValueChanged<bool>? onRdpMicrophonePermissionPromptChanged;
  final ValueChanged<bool>? onRdpFileTransferPickerChanged;

  @override
  ConsumerState<CorePersonalProfilesScreen> createState() =>
      _CorePersonalProfilesScreenState();
}

class _CorePersonalProfilesScreenState
    extends ConsumerState<CorePersonalProfilesScreen> {
  final _name = TextEditingController(),
      _host = TextEditingController(),
      _port = TextEditingController(),
      _user = TextEditingController(),
      _targetDomain = TextEditingController(),
      _gatewayHost = TextEditingController(),
      _gatewayPort = TextEditingController(text: '443'),
      _gatewayUser = TextEditingController(),
      _gatewayDomain = TextEditingController(),
      _gatewayPassword = TextEditingController();
  CorePersonalProfilesController? _controller;
  CorePersonalProfile? _editing;
  CoreManagedProfileAuthority? _sessionAuthority;
  SshSecurityStore? _sshSessionStore;
  RdpSecurityStore? _rdpSessionStore;
  VncSecurityStore? _vncSessionStore;
  _PendingLocalCleanup? _localCleanup;
  _PendingGatewaySecretCleanup? _gatewaySecretCleanup;
  PersonalSessionResource? _sessionResource;
  String? _conflictedId;
  RemoteProtocol _protocol = RemoteProtocol.ssh;
  bool _creating = false, _deleteConfirm = false, _opening = false;
  bool _sessionOpenFailed = false;
  bool _securityCommitInProgress = false;
  bool _localRetirementCommitInProgress = false;
  bool _gatewayRetirementReconciling = false;
  int _gatewayEnrollmentEpoch = 0;
  CorePersonalProfilesSnapshot? _gatewayRetirementQueued;
  CorePersonalProfilesSnapshot? _gatewayRetirementReconciled;
  _GatewayEnrollmentPhase _gatewayEnrollmentPhase =
      _GatewayEnrollmentPhase.idle;
  RdpGatewayEndpoint? _observedTarget, _observedGateway;
  RdpGatewayCertificateObservation? _gatewayObservation, _targetObservation;
  Uint8List? _pendingGatewayPassword;

  bool _current() {
    try {
      return mounted && widget.isCurrent();
    } catch (_) {
      return false;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final account = ref.read(serverAccountControllerProvider);
    if (_controller != null && !identical(_controller!.account, account)) {
      _controller!.dispose();
      _controller = null;
    }
    _controller ??= CorePersonalProfilesController(
      account: account,
      windowCurrent: _current,
    )..addListener(_changed);
    _controller!.setVisible(true);
  }

  void _changed() {
    if (!mounted) return;
    final controller = _controller;
    if (controller?.mutationOutcome == CoreProfileMutationOutcome.conflict) {
      _conflictedId = _editing?.id;
    } else if (_conflictedId != null &&
        controller?.evidence.isFreshVerified == true) {
      for (final item in controller!.profiles) {
        if (item.id == _conflictedId) {
          // Keep the user's draft, but bind its next explicit save/delete to
          // the freshly verified record revision.
          _editing = item;
          break;
        }
      }
      _conflictedId = null;
    }
    if (!_securityCommitInProgress &&
        {
          CoreProfileMutationOutcome.saved,
          CoreProfileMutationOutcome.deleted,
        }.contains(controller?.mutationOutcome)) {
      _closeEditor();
    }
    final editing = _editing;
    if (!_securityCommitInProgress &&
        _gatewayEnrollmentPhase != _GatewayEnrollmentPhase.idle &&
        (controller?.evidence.isFreshVerified != true ||
            editing == null ||
            !controller!.profiles.any(
              (value) =>
                  value.id == editing.id && value.revision == editing.revision,
            ))) {
      _resetGatewayEnrollment();
    }
    final authority = _sessionAuthority;
    if (authority != null &&
        (controller?.evidence.isFreshVerified != true ||
            !controller!.profiles.any(
              (value) =>
                  value.id == authority.profile.id &&
                  value.revision == authority.profile.revision,
            ))) {
      authority.retire();
    }
    _scheduleGatewayRetirementReconciliation();
    setState(() {});
  }

  void _scheduleGatewayRetirementReconciliation() {
    final controller = _controller;
    final snapshot = controller?.snapshot;
    if (!_current() ||
        controller == null ||
        controller.busy ||
        _securityCommitInProgress ||
        _localRetirementCommitInProgress ||
        _localCleanup != null ||
        _gatewaySecretCleanup != null ||
        controller.evidence.isFreshVerified != true ||
        snapshot == null ||
        identical(_gatewayRetirementReconciled, snapshot)) {
      return;
    }
    _gatewayRetirementQueued = snapshot;
    if (!_gatewayRetirementReconciling) {
      unawaited(_drainGatewayRetirementReconciliation());
    }
  }

  Future<void> _drainGatewayRetirementReconciliation() async {
    if (_gatewayRetirementReconciling) return;
    _gatewayRetirementReconciling = true;
    try {
      while (true) {
        final snapshot = _gatewayRetirementQueued;
        if (snapshot == null) break;
        _gatewayRetirementQueued = null;
        final controller = _controller;
        final session = controller?.account.session;
        if (!_current() ||
            controller == null ||
            controller.busy ||
            controller.evidence.isFreshVerified != true ||
            !identical(controller.snapshot, snapshot) ||
            session == null ||
            session.context != snapshot.context ||
            session.user.id != snapshot.authority.accountId ||
            session.sessionFamilyId != snapshot.authority.sessionFamilyId) {
          continue;
        }
        try {
          final namespace = RdpSecurityNamespace.coreManaged(
            endpoint: session.endpoint.baseUrl,
            coreId: snapshot.context.coreId,
            homeId: snapshot.context.homeId,
            accountId: snapshot.authority.accountId,
            sessionFamilyId: snapshot.authority.sessionFamilyId,
          );
          final security = RdpSecurityStore(namespace: namespace);
          final active = <String, int>{};
          for (final profile in snapshot.profiles) {
            if (profile.profile.protocol != RemoteProtocol.rdp) continue;
            final authority = security.fileTransferAuthority(
              profile.profile,
              profileRevision: profile.revision,
            );
            if (active.containsKey(authority.profileRef)) {
              throw const RdpFailure('invalid_record');
            }
            active[authority.profileRef] = authority.profileRevision;
          }
          bool current() =>
              _current() &&
              identical(_controller, controller) &&
              !controller.busy &&
              !_securityCommitInProgress &&
              !_localRetirementCommitInProgress &&
              _localCleanup == null &&
              _gatewaySecretCleanup == null &&
              controller.evidence.isFreshVerified == true &&
              identical(controller.snapshot, snapshot) &&
              identical(controller.account.session, session);
          await ref
              .read(rdpSchema6SecretVaultProvider)
              .reconcileRetired(
                namespaceDigest: namespace.digest,
                kind: RdpSchema6SecretKind.gatewayPassword,
                activeProfileRevisions: active,
                isCurrent: current,
              );
          if (current()) _gatewayRetirementReconciled = snapshot;
        } catch (_) {
          // The deletion-only ledger remains durable. A later verified Core
          // snapshot retries it without replaying a Core or provider mutation.
        }
      }
    } finally {
      _gatewayRetirementReconciling = false;
      if (_gatewayRetirementQueued != null && mounted) {
        unawaited(_drainGatewayRetirementReconciliation());
      }
    }
  }

  void _authorityChanged() {
    if (_sessionAuthority?.isCurrent != true) {
      scheduleMicrotask(() {
        if (mounted && _sessionAuthority?.isCurrent != true) _closeSession();
      });
    }
  }

  bool _sessionCurrent() => _current() && _sessionAuthority?.isCurrent == true;

  void _closeSession() {
    final authority = _sessionAuthority;
    _sessionAuthority = null;
    _sshSessionStore = null;
    _rdpSessionStore = null;
    _vncSessionStore = null;
    _sessionResource = null;
    authority?.removeListener(_authorityChanged);
    authority?.dispose();
    if (mounted) setState(() {});
  }

  Future<void> _openSession(
    CorePersonalProfile profile,
    PersonalSessionResource resource,
  ) async {
    final controller = _controller;
    final snapshot = controller?.snapshot;
    if (_opening ||
        !_current() ||
        controller?.evidence.isFreshVerified != true ||
        snapshot == null ||
        (profile.profile.protocol != RemoteProtocol.vnc &&
            profile.profile.username.isEmpty) ||
        !PersonalSessionPolicy.allows(profile.profile.protocol, resource)) {
      return;
    }
    _opening = true;
    _sessionOpenFailed = false;
    if (mounted) setState(() {});
    final authority = CoreManagedProfileAuthority(
      account: controller!.account,
      profile: profile,
      authority: snapshot.authority,
      ownerCurrent: _current,
    )..addListener(_authorityChanged);
    try {
      await authority.start();
      if (!_current() || !authority.isCurrent) {
        authority.dispose();
        return;
      }
      _sessionAuthority = authority;
      switch (profile.profile.protocol) {
        case RemoteProtocol.ssh:
          _sshSessionStore = authority.createSecurityStore();
        case RemoteProtocol.rdp:
          _rdpSessionStore = authority.createRdpSecurityStore();
        case RemoteProtocol.vnc:
          _vncSessionStore = authority.createVncSecurityStore();
      }
      _sessionResource = resource;
      if (mounted) setState(() {});
    } catch (_) {
      if (identical(_sessionAuthority, authority)) {
        _sessionAuthority = null;
        _sshSessionStore = null;
        _rdpSessionStore = null;
        _vncSessionStore = null;
        _sessionResource = null;
      }
      authority.removeListener(_authorityChanged);
      authority.dispose();
      if (_current()) _sessionOpenFailed = true;
    } finally {
      _opening = false;
      if (mounted) setState(() {});
    }
  }

  void _edit(CorePersonalProfile? profile) {
    _resetGatewayEnrollment();
    _editing = profile;
    _creating = profile == null;
    _deleteConfirm = false;
    _conflictedId = null;
    _protocol = profile?.profile.protocol ?? RemoteProtocol.ssh;
    _name.text = profile?.profile.name ?? '';
    _host.text = profile?.profile.host ?? '';
    _port.text = '${profile?.profile.port ?? remoteDefaultPort(_protocol)}';
    _user.text = profile?.profile.username ?? '';
    final security = profile?.rdpSecurity;
    _targetDomain.text = security?.domain ?? '';
    _gatewayHost.text = security?.gateway?.endpoint.host ?? '';
    _gatewayPort.text = '${security?.gateway?.endpoint.port ?? 443}';
    _gatewayUser.text = security?.gateway?.endpoint.username ?? '';
    _gatewayDomain.text = security?.gateway?.endpoint.domain ?? '';
    setState(() {});
  }

  void _closeEditor() {
    _resetGatewayEnrollment();
    _editing = null;
    _creating = false;
    _deleteConfirm = false;
    _conflictedId = null;
    for (final field in [
      _name,
      _host,
      _port,
      _user,
      _targetDomain,
      _gatewayHost,
      _gatewayPort,
      _gatewayUser,
      _gatewayDomain,
      _gatewayPassword,
    ]) {
      field.clear();
    }
    _gatewayPort.text = '443';
  }

  void _resetGatewayEnrollment({bool clearEnteredPassword = true}) {
    _gatewayEnrollmentEpoch += 1;
    _pendingGatewayPassword?.fillRange(0, _pendingGatewayPassword!.length, 0);
    _pendingGatewayPassword = null;
    if (clearEnteredPassword) _gatewayPassword.clear();
    _observedTarget = null;
    _observedGateway = null;
    _gatewayObservation = null;
    _targetObservation = null;
    _gatewayEnrollmentPhase = _GatewayEnrollmentPhase.idle;
  }

  bool _gatewayCurrent(CorePersonalProfile profile, int epoch) {
    final controller = _controller;
    try {
      return _current() &&
          ref.read(rdpGatewayEnrollmentAdmittedProvider).asData?.value ==
              true &&
          epoch == _gatewayEnrollmentEpoch &&
          identical(_editing, profile) &&
          controller?.evidence.isFreshVerified == true &&
          controller!.profiles.any(
            (value) =>
                value.id == profile.id && value.revision == profile.revision,
          );
    } catch (_) {
      return false;
    }
  }

  RdpGatewayEndpoint _targetEndpoint() => RdpGatewayEndpoint(
    host: normalizeRemoteHost(_host.text),
    port: int.parse(_port.text),
    username: _user.text.trim(),
    domain: _targetDomain.text.trim(),
  );

  RdpGatewayEndpoint _gatewayEndpoint() => RdpGatewayEndpoint(
    host: normalizeRemoteHost(_gatewayHost.text),
    port: int.parse(_gatewayPort.text),
    username: _gatewayUser.text.trim(),
    domain: _gatewayDomain.text.trim(),
  );

  Future<T> _withGatewayScope<T>(
    CorePersonalProfile profile,
    int epoch,
    Future<T> Function(RdpSchema6SecretScope scope, bool Function() current)
    action,
  ) async {
    final controller = _controller!;
    final snapshot = controller.snapshot!;
    final authority = CoreManagedProfileAuthority(
      account: controller.account,
      profile: profile,
      authority: snapshot.authority,
      ownerCurrent: () => _gatewayCurrent(profile, epoch),
    );
    try {
      await authority.start();
      if (!_gatewayCurrent(profile, epoch) || !authority.isCurrent) {
        throw const RdpFailure('retired');
      }
      final transferAuthority = authority
          .createRdpSecurityStore()
          .fileTransferAuthority(
            profile.profile,
            profileRevision: profile.revision,
          );
      final scope = RdpSchema6SecretScope(
        namespaceDigest: transferAuthority.namespaceDigest,
        profileRef: transferAuthority.profileRef,
        profileRevision: transferAuthority.profileRevision,
      );
      bool current() => _gatewayCurrent(profile, epoch) && authority.isCurrent;
      final value = await action(scope, current);
      if (!current()) throw const RdpFailure('retired');
      return value;
    } finally {
      authority.dispose();
    }
  }

  Future<void> _inspectGateway() async {
    final profile = _editing;
    if (ref.read(rdpGatewayEnrollmentAdmittedProvider).asData?.value != true ||
        profile == null ||
        profile.profile.protocol != RemoteProtocol.rdp ||
        _gatewaySecretCleanup != null ||
        _gatewayEnrollmentPhase == _GatewayEnrollmentPhase.inspectingGateway ||
        _gatewayEnrollmentPhase == _GatewayEnrollmentPhase.inspectingTarget ||
        _gatewayEnrollmentPhase == _GatewayEnrollmentPhase.saving) {
      return;
    }
    _resetGatewayEnrollment(clearEnteredPassword: false);
    final epoch = _gatewayEnrollmentEpoch;
    _gatewayEnrollmentPhase = _GatewayEnrollmentPhase.inspectingGateway;
    if (mounted) setState(() {});
    try {
      final target = _targetEndpoint();
      final gateway = _gatewayEndpoint();
      final observation = await _withGatewayScope(profile, epoch, (
        scope,
        current,
      ) async {
        final coordinator = RdpGatewayEnrollmentCoordinator(
          engine: ref.read(rdpGatewayEnrollmentEngineFactoryProvider)(),
          secrets: ref.read(rdpSchema6SecretVaultProvider),
          scope: scope,
          isCurrent: current,
        );
        try {
          return await coordinator.inspectGateway(
            target: target,
            gateway: gateway,
          );
        } finally {
          coordinator.close();
        }
      });
      if (!_gatewayCurrent(profile, epoch)) return;
      _observedTarget = target;
      _observedGateway = gateway;
      _gatewayObservation = observation;
      _gatewayEnrollmentPhase = _GatewayEnrollmentPhase.gatewayObserved;
    } catch (_) {
      if (_gatewayCurrent(profile, epoch)) {
        _gatewayEnrollmentPhase = _GatewayEnrollmentPhase.failed;
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _inspectTarget() async {
    final profile = _editing;
    final gatewayObservation = _gatewayObservation;
    final observedTarget = _observedTarget;
    final observedGateway = _observedGateway;
    if (ref.read(rdpGatewayEnrollmentAdmittedProvider).asData?.value != true ||
        profile == null ||
        gatewayObservation == null ||
        observedTarget == null ||
        observedGateway == null ||
        _gatewayEnrollmentPhase != _GatewayEnrollmentPhase.gatewayObserved) {
      return;
    }
    final epoch = _gatewayEnrollmentEpoch;
    Uint8List? retained;
    RdpSchema6OwnedSecretCleanup? temporaryCleanup;
    _gatewayEnrollmentPhase = _GatewayEnrollmentPhase.inspectingTarget;
    if (mounted) setState(() {});
    try {
      if (_targetEndpoint() != observedTarget ||
          _gatewayEndpoint() != observedGateway) {
        throw const RdpFailure('profile_changed');
      }
      final entered = Uint8List.fromList(utf8.encode(_gatewayPassword.text));
      _gatewayPassword.clear();
      retained = Uint8List.fromList(entered);
      final observation = await _withGatewayScope(profile, epoch, (
        scope,
        current,
      ) async {
        final vault = ref.read(rdpSchema6SecretVaultProvider);
        temporaryCleanup = await vault.saveOwned(
          scope: scope,
          kind: RdpSchema6SecretKind.gatewayPassword,
          secret: entered,
          isCurrent: current,
        );
        final coordinator = RdpGatewayEnrollmentCoordinator(
          engine: ref.read(rdpGatewayEnrollmentEngineFactoryProvider)(),
          secrets: vault,
          scope: scope,
          isCurrent: current,
        );
        try {
          return await coordinator.inspectTarget(
            target: observedTarget,
            gateway: RdpPinnedGatewayEndpoint(
              endpoint: observedGateway,
              fingerprint: gatewayObservation.certificate.fingerprint,
            ),
            gatewaySecret: temporaryCleanup!.reference,
          );
        } finally {
          coordinator.close();
          if (temporaryCleanup case final cleanup?) {
            await cleanup.delete();
            temporaryCleanup = null;
          }
        }
      });
      if (!_gatewayCurrent(profile, epoch)) return;
      _pendingGatewayPassword?.fillRange(0, _pendingGatewayPassword!.length, 0);
      _pendingGatewayPassword = retained;
      retained = null;
      _targetObservation = observation;
      _gatewayEnrollmentPhase = _GatewayEnrollmentPhase.targetObserved;
    } catch (_) {
      if (temporaryCleanup case final cleanup?) {
        try {
          await cleanup.delete();
          temporaryCleanup = null;
        } catch (_) {
          _gatewaySecretCleanup ??= _PendingGatewaySecretCleanup(
            profileId: profile.id,
            cleanup: cleanup,
            closeEditorOnSuccess: false,
          );
        }
      }
      if (_gatewayCurrent(profile, epoch)) {
        _gatewayEnrollmentPhase = _GatewayEnrollmentPhase.failed;
      }
    } finally {
      retained?.fillRange(0, retained.length, 0);
    }
    if (mounted) setState(() {});
  }

  Future<void> _acceptTargetAndSave() async {
    final profile = _editing;
    final target = _observedTarget;
    final gateway = _observedGateway;
    final gatewayObservation = _gatewayObservation;
    final targetObservation = _targetObservation;
    final secret = _pendingGatewayPassword;
    final controller = _controller;
    if (ref.read(rdpGatewayEnrollmentAdmittedProvider).asData?.value != true ||
        profile == null ||
        target == null ||
        gateway == null ||
        gatewayObservation == null ||
        targetObservation == null ||
        secret == null ||
        controller == null ||
        _gatewayEnrollmentPhase != _GatewayEnrollmentPhase.targetObserved) {
      return;
    }
    final epoch = _gatewayEnrollmentEpoch;
    RdpSchema6OwnedSecretCleanup? oldSecretCleanup;
    _gatewayEnrollmentPhase = _GatewayEnrollmentPhase.saving;
    _securityCommitInProgress = true;
    if (mounted) setState(() {});
    try {
      if (_targetEndpoint() != target || _gatewayEndpoint() != gateway) {
        throw const RdpFailure('profile_changed');
      }
      final projection = RdpCoreSecurityProjection(
        domain: target.domain,
        certificateFingerprint: targetObservation.certificate.fingerprint,
        gateway: RdpCoreGatewaySecurity(
          endpoint: gateway,
          certificateFingerprint: gatewayObservation.certificate.fingerprint,
        ),
      );
      oldSecretCleanup = await _withGatewayScope(
        profile,
        epoch,
        (scope, current) => ref
            .read(rdpSchema6SecretVaultProvider)
            .ownCurrentForCleanup(
              scope: scope,
              kind: RdpSchema6SecretKind.gatewayPassword,
              isCurrent: current,
            ),
      );
      await controller.updateRdpSecurity(
        profile,
        projection,
        ownerCurrent: () => _gatewayCurrent(profile, epoch),
      );
      if (!_current() ||
          controller.mutationOutcome != CoreProfileMutationOutcome.saved) {
        throw const RdpFailure('retired');
      }
      final updated = controller.profiles.where(
        (value) => value.id == profile.id,
      );
      if (updated.length != 1 || updated.single.rdpSecurity != projection) {
        throw const RdpFailure('invalid_response');
      }
      final currentProfile = updated.single;
      final snapshot = controller.snapshot!;
      final authority = CoreManagedProfileAuthority(
        account: controller.account,
        profile: currentProfile,
        authority: snapshot.authority,
        ownerCurrent: _current,
      );
      try {
        await authority.start();
        final transferAuthority = authority
            .createRdpSecurityStore()
            .fileTransferAuthority(
              currentProfile.profile,
              profileRevision: currentProfile.revision,
            );
        final scope = RdpSchema6SecretScope(
          namespaceDigest: transferAuthority.namespaceDigest,
          profileRef: transferAuthority.profileRef,
          profileRevision: transferAuthority.profileRevision,
        );
        await ref
            .read(rdpSchema6SecretVaultProvider)
            .saveCurrent(
              scope: scope,
              kind: RdpSchema6SecretKind.gatewayPassword,
              secret: Uint8List.fromList(secret),
              isCurrent: () => _current() && authority.isCurrent,
            );
      } finally {
        authority.dispose();
      }
      _pendingGatewayPassword?.fillRange(0, secret.length, 0);
      _pendingGatewayPassword = null;
      if (oldSecretCleanup case final cleanup?) {
        try {
          await cleanup.delete();
        } catch (_) {
          _gatewaySecretCleanup = _PendingGatewaySecretCleanup(
            profileId: currentProfile.id,
            cleanup: cleanup,
            closeEditorOnSuccess: true,
          );
          _securityCommitInProgress = false;
          _gatewayEnrollmentPhase = _GatewayEnrollmentPhase.failed;
          _editing = currentProfile;
          if (mounted) setState(() {});
          return;
        }
      }
      _securityCommitInProgress = false;
      _closeEditor();
    } catch (_) {
      secret.fillRange(0, secret.length, 0);
      _pendingGatewayPassword = null;
      _securityCommitInProgress = false;
      if (_current()) {
        _gatewayEnrollmentPhase = _GatewayEnrollmentPhase.failed;
        final current = controller.profiles.where(
          (value) => value.id == profile.id,
        );
        if (current.length == 1) _editing = current.single;
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _retryGatewaySecretCleanup(
    _PendingGatewaySecretCleanup pending,
  ) async {
    if (!identical(_gatewaySecretCleanup, pending) || pending.retrying) return;
    pending.retrying = true;
    if (mounted) setState(() {});
    try {
      await pending.cleanup.delete();
      if (!identical(_gatewaySecretCleanup, pending)) return;
      _gatewaySecretCleanup = null;
      if (pending.closeEditorOnSuccess && _editing?.id == pending.profileId) {
        _closeEditor();
      } else {
        _resetGatewayEnrollment();
      }
    } catch (_) {
      if (identical(_gatewaySecretCleanup, pending)) pending.retrying = false;
    }
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    final controller = _controller;
    if (controller == null || !_current()) return;
    try {
      final port = int.tryParse(_port.text);
      if (port == null || port < 1 || port > 65535) return;
      final desired = RemoteProfile(
        id:
            _editing?.id ??
            List.generate(
              16,
              (_) => Random.secure()
                  .nextInt(256)
                  .toRadixString(16)
                  .padLeft(2, '0'),
            ).join(),
        name: _name.text.trim(),
        protocol: _protocol,
        host: normalizeRemoteHost(_host.text),
        port: port,
        username: _user.text.trim(),
      );
      desired.toJson();
      final target = _editing;
      if (target == null) {
        await controller.create(desired, ownerCurrent: _current);
      } else {
        await controller.update(target, desired, ownerCurrent: _current);
      }
    } catch (_) {
      // Local validation remains local and carries no entered metadata.
      if (mounted) setState(() {});
    }
  }

  Future<void> _deleteProfile(CorePersonalProfile target) async {
    final controller = _controller;
    final snapshot = controller?.snapshot;
    if (controller == null ||
        snapshot == null ||
        controller.busy ||
        _localCleanup != null ||
        !_current()) {
      return;
    }
    _localRetirementCommitInProgress = true;
    final cleanupAuthority = CoreManagedProfileAuthority(
      account: controller.account,
      profile: target,
      authority: snapshot.authority,
      ownerCurrent: _current,
    );
    var retainedForRetry = false;
    try {
      final Future<void> Function(bool Function()) erase;
      switch (target.profile.protocol) {
        case RemoteProtocol.ssh:
          final store = cleanupAuthority.createSecurityStore();
          erase = (current) =>
              store.forgetProfileRecords(target.profile, isCurrent: current);
        case RemoteProtocol.rdp:
          final store = cleanupAuthority.createRdpSecurityStore();
          final transferAuthority = store.fileTransferAuthority(
            target.profile,
            profileRevision: target.revision,
          );
          final secretCleanup = await ref
              .read(rdpSchema6SecretVaultProvider)
              .ownCurrentForCleanup(
                scope: RdpSchema6SecretScope(
                  namespaceDigest: transferAuthority.namespaceDigest,
                  profileRef: transferAuthority.profileRef,
                  profileRevision: transferAuthority.profileRevision,
                ),
                kind: RdpSchema6SecretKind.gatewayPassword,
                isCurrent: () => cleanupAuthority.isCurrent && _current(),
              );
          erase = (current) async {
            await store.forgetProfileRecords(
              target.profile,
              isCurrent: current,
            );
            await secretCleanup?.delete();
          };
        case RemoteProtocol.vnc:
          final store = cleanupAuthority.createVncSecurityStore();
          erase = (current) =>
              store.forgetProfileRecords(target.profile, isCurrent: current);
      }
      await controller.delete(target, ownerCurrent: _current);
      if (_current() &&
          controller.mutationOutcome == CoreProfileMutationOutcome.deleted &&
          !controller.profiles.any((profile) => profile.id == target.id)) {
        final pending = _PendingLocalCleanup(
          authority: cleanupAuthority,
          erase: erase,
        );
        _localCleanup = pending;
        retainedForRetry = true;
        await _retryLocalCleanup(pending);
      }
    } finally {
      if (!retainedForRetry) cleanupAuthority.dispose();
      _localRetirementCommitInProgress = false;
      _scheduleGatewayRetirementReconciliation();
    }
  }

  Future<void> _retryLocalCleanup(_PendingLocalCleanup pending) async {
    if (!identical(_localCleanup, pending) || !_current()) return;
    pending.phase = _LocalCleanupPhase.retrying;
    if (mounted) setState(() {});
    try {
      await pending.erase(
        () =>
            identical(_localCleanup, pending) &&
            pending.authority.isCurrent &&
            _current(),
      );
      if (!identical(_localCleanup, pending)) return;
      _localCleanup = null;
      pending.authority.dispose();
    } on SshFailure {
      if (!identical(_localCleanup, pending)) return;
      pending.phase = _LocalCleanupPhase.failed;
    } on RdpFailure {
      if (!identical(_localCleanup, pending)) return;
      pending.phase = _LocalCleanupPhase.failed;
    } on VncFailure {
      if (!identical(_localCleanup, pending)) return;
      pending.phase = _LocalCleanupPhase.failed;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    final authority = _sessionAuthority;
    authority?.removeListener(_authorityChanged);
    authority?.dispose();
    _localCleanup?.authority.dispose();
    _localCleanup = null;
    _gatewayRetirementQueued = null;
    _controller?.removeListener(_changed);
    _controller?.setVisible(false);
    _controller?.dispose();
    _resetGatewayEnrollment();
    for (final field in [
      _name,
      _host,
      _port,
      _user,
      _targetDomain,
      _gatewayHost,
      _gatewayPort,
      _gatewayUser,
      _gatewayDomain,
      _gatewayPassword,
    ]) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(serverAccountControllerProvider);
    final gatewayAdmitted =
        ref.watch(rdpGatewayEnrollmentAdmittedProvider).asData?.value == true;
    final l = AppLocalizations.of(context);
    final controller = _controller!;
    final sessionProfile = _sessionAuthority?.profile.profile;
    if (sessionProfile != null &&
        (_sshSessionStore != null ||
            _rdpSessionStore != null ||
            _vncSessionStore != null)) {
      final close = _closeSession;
      return switch ((sessionProfile.protocol, _sessionResource)) {
        (RemoteProtocol.ssh, PersonalSessionResource.sshTerminal) =>
          SshTerminalPanel(
            key: ValueKey('core-ssh-${sessionProfile.id}'),
            profile: sessionProfile,
            securityStore: _sshSessionStore!,
            isCurrent: _sessionCurrent,
            onBack: close,
          ),
        (RemoteProtocol.ssh, PersonalSessionResource.sftpFiles) =>
          SftpBrowserPanel(
            key: ValueKey('core-sftp-${sessionProfile.id}'),
            profile: sessionProfile,
            securityStore: _sshSessionStore!,
            isCurrent: _sessionCurrent,
            onBack: close,
          ),
        (RemoteProtocol.ssh, PersonalSessionResource.sshTunnel) =>
          SshTunnelPanel(
            key: ValueKey('core-tunnel-${sessionProfile.id}'),
            profile: sessionProfile,
            securityStore: _sshSessionStore!,
            isCurrent: _sessionCurrent,
            onBack: close,
          ),
        (RemoteProtocol.rdp, PersonalSessionResource.desktop) =>
          RdpSessionPanel(
            key: ValueKey('core-rdp-${sessionProfile.id}'),
            profile: sessionProfile,
            authorityRevision: _sessionAuthority!.profile.revision,
            coreSecurity: _sessionAuthority!.profile.rdpSecurity,
            securityStore: _rdpSessionStore!,
            isCurrent: _sessionCurrent,
            onMicrophonePermissionPromptChanged:
                widget.onRdpMicrophonePermissionPromptChanged,
            onFileTransferPickerChanged: widget.onRdpFileTransferPickerChanged,
            onBack: close,
          ),
        (RemoteProtocol.vnc, PersonalSessionResource.desktop) =>
          VncSessionPanel(
            key: ValueKey('core-vnc-${sessionProfile.id}'),
            profile: sessionProfile,
            securityStore: _vncSessionStore!,
            isCurrent: _sessionCurrent,
            onBack: close,
          ),
        _ => const SizedBox.shrink(),
      };
    }
    Widget action(String key, String title, VoidCallback? onTap) =>
        SettingsActionTile(
          key: ValueKey(key),
          title: Text(title),
          onTap: controller.busy || !_current() ? null : onTap,
        );
    Widget field(
      String key,
      String label,
      TextEditingController value, {
      TextInputType? keyboard,
      bool last = false,
      bool secret = false,
    }) => Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label),
          const SizedBox(height: 6),
          CupertinoTextField(
            key: ValueKey(key),
            controller: value,
            enabled: controller.canMutate && !controller.busy,
            keyboardType: keyboard,
            autocorrect: false,
            enableSuggestions: false,
            obscureText: secret,
            padding: const EdgeInsets.all(14),
            textInputAction: last ? TextInputAction.done : TextInputAction.next,
            onSubmitted: last ? (_) => _save() : null,
          ),
        ],
      ),
    );

    final conflict =
        controller.mutationOutcome == CoreProfileMutationOutcome.conflict;
    return AppPageScaffold(
      child: CustomScrollView(
        key: const ValueKey('core-profiles-scroll'),
        slivers: [
          CupertinoSliverNavigationBar(
            automaticallyImplyLeading: false,
            largeTitle: Text(l.remoteAccessCoreProfiles),
          ),
          SliverSafeArea(
            top: false,
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                SettingsSection(
                  children: [
                    action('core-profiles-back', l.commonBack, widget.onBack),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Semantics(
                    key: const ValueKey('core-profile-source-status'),
                    container: true,
                    liveRegion: true,
                    label:
                        '${l.remoteAccessCoreManaged}. ${l.remoteAccessCoreScope}',
                    child: ExcludeSemantics(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l.remoteAccessCoreManaged,
                            style: CupertinoTheme.of(context)
                                .textTheme
                                .navTitleTextStyle,
                          ),
                          const SizedBox(height: 6),
                          Text(l.remoteAccessCoreScope),
                          const SizedBox(height: 12),
                          ConnectionEvidenceStatus(
                            evidence: controller.evidence,
                            compact: true,
                            showTimestamp: true,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (controller.busy || _opening)
                  const Center(child: CupertinoActivityIndicator()),
                if (_sessionOpenFailed)
                  Padding(
                    key: const ValueKey('core-profile-session-open-failed'),
                    padding: const EdgeInsets.all(20),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(l.remoteAccessCoreUnavailable),
                    ),
                  ),
                if (conflict)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(l.remoteAccessCoreConflict),
                    ),
                  ),
                if (controller.failure != null && !conflict)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(l.remoteAccessCoreUnavailable),
                    ),
                  ),
                SettingsSection(
                  children: [
                    action(
                      'core-profiles-refresh',
                      conflict ? l.remoteAccessCoreResolve : l.commonRefresh,
                      controller.canRefresh ? controller.refresh : null,
                    ),
                    action(
                      'core-profiles-add',
                      l.remoteAccessCoreAdd,
                      controller.canMutate ? () => _edit(null) : null,
                    ),
                  ],
                ),
                if (_creating || _editing != null)
                  SettingsSection(
                    children: [
                      field('core-profile-name', l.remoteAccessName, _name),
                      for (final protocol in RemoteProtocol.values)
                        action(
                          'core-profile-protocol-${protocol.name}',
                          '${protocol.name.toUpperCase()}${_protocol == protocol ? ' ✓' : ''}',
                          () {
                            _resetGatewayEnrollment();
                            final old = remoteDefaultPort(_protocol);
                            _protocol = protocol;
                            if (_port.text == '$old') {
                              _port.text = '${remoteDefaultPort(protocol)}';
                            }
                            setState(() {});
                          },
                        ),
                      field('core-profile-host', l.remoteAccessHost, _host),
                      field(
                        'core-profile-port',
                        l.remoteAccessPort,
                        _port,
                        keyboard: TextInputType.number,
                      ),
                      field(
                        'core-profile-user',
                        l.remoteAccessUsername,
                        _user,
                        last: true,
                      ),
                      if (!_creating &&
                          _protocol == RemoteProtocol.rdp &&
                          gatewayAdmitted) ...[
                        field(
                          'core-rdp-target-domain',
                          l.rdpDomain,
                          _targetDomain,
                        ),
                        field(
                          'core-rdp-gateway-host',
                          l.rdpGatewayHost,
                          _gatewayHost,
                        ),
                        field(
                          'core-rdp-gateway-port',
                          l.rdpGatewayPort,
                          _gatewayPort,
                          keyboard: TextInputType.number,
                        ),
                        field(
                          'core-rdp-gateway-user',
                          l.rdpGatewayUsername,
                          _gatewayUser,
                        ),
                        field(
                          'core-rdp-gateway-domain',
                          l.rdpDomain,
                          _gatewayDomain,
                        ),
                        field(
                          'core-rdp-gateway-password',
                          l.rdpGatewayPassword,
                          _gatewayPassword,
                          secret: true,
                        ),
                        action(
                          'core-rdp-inspect-gateway',
                          l.rdpCertificateReview,
                          _gatewayEnrollmentPhase ==
                                      _GatewayEnrollmentPhase.idle ||
                                  _gatewayEnrollmentPhase ==
                                      _GatewayEnrollmentPhase.failed
                              ? () => unawaited(_inspectGateway())
                              : null,
                        ),
                        if (_gatewayObservation case final observation?) ...[
                          Padding(
                            key: const ValueKey('core-rdp-gateway-pin'),
                            padding: const EdgeInsets.all(20),
                            child: SelectableText(
                              observation.certificate.fingerprint,
                            ),
                          ),
                          if (_gatewayEnrollmentPhase ==
                              _GatewayEnrollmentPhase.gatewayObserved)
                            action(
                              'core-rdp-accept-gateway',
                              l.rdpTrustCertificate,
                              () => unawaited(_inspectTarget()),
                            ),
                        ],
                        if (_targetObservation case final observation?) ...[
                          Padding(
                            key: const ValueKey('core-rdp-target-pin'),
                            padding: const EdgeInsets.all(20),
                            child: SelectableText(
                              observation.certificate.fingerprint,
                            ),
                          ),
                          if (_gatewayEnrollmentPhase ==
                              _GatewayEnrollmentPhase.targetObserved)
                            action(
                              'core-rdp-accept-target-save',
                              l.commonSave,
                              () => unawaited(_acceptTargetAndSave()),
                            ),
                        ],
                        if (_gatewayEnrollmentPhase ==
                            _GatewayEnrollmentPhase.failed)
                          Padding(
                            key: const ValueKey(
                              'core-rdp-gateway-enrollment-failed',
                            ),
                            padding: const EdgeInsets.all(20),
                            child: Text(l.remoteAccessCoreUnavailable),
                          ),
                      ],
                      action('core-profile-save', l.commonSave, _save),
                      action('core-profile-cancel', l.commonCancel, () {
                        _closeEditor();
                        setState(() {});
                      }),
                    ],
                  )
                else if (controller.loaded || controller.profiles.isNotEmpty)
                  SettingsSection(
                    children: [
                      if (controller.loaded && controller.profiles.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(l.remoteAccessCoreEmpty),
                        ),
                      for (final item in controller.profiles) ...[
                        SettingsActionTile(
                          key: ValueKey('core-profile-${item.id}'),
                          title: Text(item.profile.name),
                          additionalInfo: Text(
                            '${item.profile.protocol.name.toUpperCase()} · ${item.profile.address}',
                          ),
                          onTap: controller.canMutate
                              ? () => _edit(item)
                              : null,
                        ),
                        if (item.profile.protocol == RemoteProtocol.ssh &&
                            item.profile.username.isNotEmpty) ...[
                          action(
                            'core-profile-ssh-open-${item.id}',
                            l.sshTitle,
                            () => _openSession(
                              item,
                              PersonalSessionResource.sshTerminal,
                            ),
                          ),
                          action(
                            'core-profile-sftp-open-${item.id}',
                            l.sftpTitle,
                            () => _openSession(
                              item,
                              PersonalSessionResource.sftpFiles,
                            ),
                          ),
                          action(
                            'core-profile-tunnel-open-${item.id}',
                            l.sshTunnelTitle,
                            () => _openSession(
                              item,
                              PersonalSessionResource.sshTunnel,
                            ),
                          ),
                        ],
                        if (item.profile.protocol == RemoteProtocol.rdp &&
                            item.profile.username.isNotEmpty)
                          action(
                            'core-profile-rdp-open-${item.id}',
                            l.rdpTitle,
                            () => _openSession(
                              item,
                              PersonalSessionResource.desktop,
                            ),
                          ),
                        if (item.profile.protocol == RemoteProtocol.vnc)
                          action(
                            'core-profile-vnc-open-${item.id}',
                            l.vncTitle,
                            () => _openSession(
                              item,
                              PersonalSessionResource.desktop,
                            ),
                          ),
                      ],
                    ],
                  ),
                if (_localCleanup case final cleanup?)
                  SettingsSection(
                    children: [
                      Padding(
                        key: const ValueKey(
                          'core-profile-local-cleanup-failed',
                        ),
                        padding: const EdgeInsets.all(20),
                        child: Text(l.sshStorageFailed),
                      ),
                      action(
                        'core-profile-local-cleanup-retry',
                        l.commonRetry,
                        cleanup.phase == _LocalCleanupPhase.failed
                            ? () => unawaited(_retryLocalCleanup(cleanup))
                            : null,
                      ),
                    ],
                  ),
                if (_gatewaySecretCleanup case final cleanup?)
                  SettingsSection(
                    children: [
                      Padding(
                        key: const ValueKey('core-rdp-secret-cleanup-failed'),
                        padding: const EdgeInsets.all(20),
                        child: Text(l.sshStorageFailed),
                      ),
                      action(
                        'core-rdp-secret-cleanup-retry',
                        l.commonRetry,
                        cleanup.retrying
                            ? null
                            : () => unawaited(
                                _retryGatewaySecretCleanup(cleanup),
                              ),
                      ),
                    ],
                  ),
                if (_editing != null && !_creating)
                  SettingsSection(
                    children: [
                      if (_deleteConfirm) ...[
                        Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(
                            l.remoteAccessDeleteConfirm(_editing!.profile.name),
                          ),
                        ),
                        action(
                          'core-profile-delete-confirm',
                          l.commonDelete,
                          () => unawaited(_deleteProfile(_editing!)),
                        ),
                      ] else
                        action('core-profile-delete', l.commonDelete, () {
                          setState(() => _deleteConfirm = true);
                        }),
                    ],
                  ),
                const SizedBox(height: 32),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}
