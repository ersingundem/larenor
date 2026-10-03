import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/remote_access/data/remote_profiles.dart';
import 'package:larenor/features/remote_access/rdp/rdp_engine.dart';
import 'package:larenor/features/remote_access/rdp/rdp_models.dart';
import 'package:larenor/features/remote_access/rdp/rdp_schema6_controller.dart';
import 'package:larenor/features/remote_access/rdp/rdp_schema6_engine.dart';
import 'package:larenor/features/remote_access/rdp/rdp_schema6_models.dart';
import 'package:larenor/features/remote_access/rdp/rdp_schema6_security_store.dart';
import 'package:larenor/features/remote_access/rdp/rdp_schema6_session_authority.dart';
import 'package:larenor/features/remote_access/rdp/rdp_security_store.dart';
import 'package:larenor/features/remote_access/rdp/rdp_session_controller.dart';

import 'rdp_models_test.dart' show packagedCapabilities;

const pin = 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
final authority = RdpFileTransferAuthority(
  namespaceDigest: ''.padLeft(64, 'a'),
  profileRef: ''.padLeft(64, 'b'),
  profileRevision: 2,
);
const grant = RdpFileTransferGrant(
  id: '0123456789abcdef0123456789abcdef',
  revision: 4,
);
final sessionOwner = RdpSchema6SessionOwner(
  requestId: '12345678-1234-4234-9234-123456789abc',
  revision: 9,
);

RdpTransferReceipt receipt(RdpTransferState state) => RdpTransferReceipt(
  requestId: 'request',
  authorityId: authority.authorityId,
  grant: grant,
  transferId: 'fedcba9876543210fedcba9876543210',
  state: state,
);

final class FakeTransferPort implements RdpSchema6TransferPort {
  RdpTransferState drainState = RdpTransferState.sealed;
  RdpTransferState saveState = RdpTransferState.saved;
  Object? drainError;
  Completer<void>? prepareGate;
  int saves = 0;
  int prepares = 0;

  @override
  Future<RdpTransferReceipt> prepare({
    required RdpFileTransferAuthority authority,
    required RdpFileTransferGrant grant,
    required RdpSchema6SessionOwner sessionOwner,
    required bool Function() isCurrent,
  }) async {
    prepares += 1;
    await prepareGate?.future;
    return receipt(RdpTransferState.prepared);
  }

  @override
  Future<RdpTransferReceipt> observe({
    required RdpFileTransferAuthority authority,
    required RdpFileTransferGrant grant,
    required String transferId,
    required RdpSchema6SessionOwner sessionOwner,
    required bool Function() isCurrent,
  }) async => receipt(RdpTransferState.active);

  @override
  Future<RdpTransferReceipt> drain({
    required RdpFileTransferAuthority authority,
    required RdpFileTransferGrant grant,
    required String transferId,
    required RdpSchema6SessionOwner sessionOwner,
    required bool Function() isCurrent,
  }) async {
    if (drainError case final error?) throw error;
    return receipt(drainState);
  }

  @override
  Future<RdpTransferReceipt> saveReceived({
    required RdpFileTransferAuthority authority,
    required RdpFileTransferGrant grant,
    required String transferId,
    required RdpSchema6SessionOwner sessionOwner,
    required bool Function() isCurrent,
  }) async {
    saves += 1;
    return receipt(saveState);
  }
}

final class FakeGatewayEngine implements RdpGatewayEnrollmentEngine {
  final targetGate = Completer<void>();
  Uint8List? observedSecret;
  bool closed = false;

  @override
  Future<RdpGatewayCertificateObservation> inspectGateway({
    required RdpGatewayEndpoint target,
    required RdpGatewayEndpoint gateway,
    required bool Function() isCurrent,
  }) async => RdpGatewayCertificateObservation(
    requestId: 'one',
    kind: RdpGatewayCertificateKind.gateway,
    certificate: const RdpCertificatePin(
      algorithm: 'spki-sha256',
      fingerprint: pin,
    ),
  );

  @override
  Future<RdpGatewayCertificateObservation> inspectTargetThroughGateway({
    required RdpGatewayEndpoint target,
    required RdpPinnedGatewayEndpoint gateway,
    required RdpOwnedSecretBuffer gatewayPassword,
    required bool Function() isCurrent,
  }) async {
    observedSecret = gatewayPassword.bytes;
    await targetGate.future;
    return RdpGatewayCertificateObservation(
      requestId: 'two',
      kind: RdpGatewayCertificateKind.target,
      certificate: const RdpCertificatePin(
        algorithm: 'spki-sha256',
        fingerprint: pin,
      ),
    );
  }

  @override
  void close() => closed = true;
}

final class FakeSessionChannel implements RdpChannel {
  final _done = Completer<void>();
  @override
  Future<void> get done => _done.future;
  @override
  void close() {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  void key(RdpKeyEvent event) {}
  @override
  void pointer(RdpPointerEvent event) {}
  @override
  void relativePointer(RdpRelativePointerEvent event) {}
  @override
  void resize(RdpDisplaySpec display) {}
  @override
  Future<bool> sendClipboardText(String value) async => false;
  @override
  void text(String value) {}
  @override
  void wheel(RdpWheelEvent event) {}
}

class FakeOwnedSessionGateway implements RdpSchema6NativeSessionGateway {
  final channel = FakeSessionChannel();
  RdpSchema6SessionBinding? binding;
  RdpSessionRequest? request;

  @override
  Future<RdpChannel> openOwned(
    RdpSessionRequest request, {
    required RdpCredential credential,
    required RdpSchema6SessionBinding binding,
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) throw const RdpFailure('retired');
    this.request = request;
    this.binding = binding;
    return channel;
  }

  @override
  Future<RdpCapabilities> capabilities({required bool Function() isCurrent}) =>
      throw UnimplementedError();
  @override
  Future<RdpCertificateProbe> inspect(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) => throw UnimplementedError();
  @override
  Future<RdpChannel> open(
    RdpSessionRequest request, {
    required RdpCredential? credential,
    required bool Function() isCurrent,
  }) => throw UnimplementedError();
  @override
  void close() {}
}

final class FakeCurrentVault implements RdpSchema6CurrentSecretVault {
  @override
  Future<void> reconcileRetired({
    required String namespaceDigest,
    required RdpSchema6SecretKind kind,
    required Map<String, int> activeProfileRevisions,
    required bool Function() isCurrent,
  }) => throw UnimplementedError();

  @override
  Future<RdpOwnedSecretBuffer?> resolveCurrent({
    required RdpSchema6SecretScope scope,
    required RdpSchema6SecretKind kind,
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) throw const RdpFailure('retired');
    return RdpOwnedSecretBuffer(Uint8List.fromList('gateway-secret'.codeUnits));
  }

  @override
  Future<RdpDeviceSecretReference> saveCurrent({
    required RdpSchema6SecretScope scope,
    required RdpSchema6SecretKind kind,
    required Uint8List secret,
    required bool Function() isCurrent,
  }) => throw UnimplementedError();
  @override
  Future<void> deleteCurrent({
    required RdpSchema6SecretScope scope,
    required RdpSchema6SecretKind kind,
    required bool Function() isCurrent,
  }) => throw UnimplementedError();
  @override
  Future<RdpSchema6OwnedSecretCleanup?> ownCurrentForCleanup({
    required RdpSchema6SecretScope scope,
    required RdpSchema6SecretKind kind,
    required bool Function() isCurrent,
  }) => throw UnimplementedError();
  @override
  Future<RdpSchema6OwnedSecretCleanup> saveOwned({
    required RdpSchema6SecretScope scope,
    required RdpSchema6SecretKind kind,
    required Uint8List secret,
    required bool Function() isCurrent,
  }) => throw UnimplementedError();
  @override
  Future<RdpDeviceSecretReference> save({
    required RdpSchema6SecretScope scope,
    required RdpSchema6SecretKind kind,
    required Uint8List secret,
    required bool Function() isCurrent,
  }) => throw UnimplementedError();
  @override
  Future<RdpOwnedSecretBuffer> resolve({
    required RdpSchema6SecretScope scope,
    required RdpSchema6SecretKind kind,
    required RdpDeviceSecretReference reference,
    required bool Function() isCurrent,
  }) => throw UnimplementedError();
  @override
  Future<void> delete({
    required RdpSchema6SecretScope scope,
    required RdpSchema6SecretKind kind,
    required RdpDeviceSecretReference reference,
    required bool Function() isCurrent,
  }) => throw UnimplementedError();
}

final class FakeTrust implements RdpTrustStore {
  @override
  Future<void> checkProfile(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) async {}
  @override
  Future<RdpCertificatePin?> readPin(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) async => null;
  @override
  Future<void> trust(
    RemoteProfile profile,
    RdpCertificatePin value, {
    required bool Function() isCurrent,
  }) async {}
}

final class FakeCredentialVault implements RdpCredentialVault {
  @override
  Future<RdpCredential?> readCredential(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) async => const RdpCredential(password: 'target-secret');
  @override
  Future<void> saveCredential(
    RemoteProfile profile,
    RdpCredential credential, {
    required bool Function() isCurrent,
  }) => throw UnimplementedError();
  @override
  Future<void> deleteCredential(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) => throw UnimplementedError();
}

final class FakeGatewayOnlyRuntime extends FakeOwnedSessionGateway {
  RdpCredential? credential;

  @override
  Future<RdpCapabilities> capabilities({
    required bool Function() isCurrent,
  }) async => RdpCapabilities.fromJson(packagedCapabilities());

  @override
  Future<RdpChannel> openOwned(
    RdpSessionRequest request, {
    required RdpCredential credential,
    required RdpSchema6SessionBinding binding,
    required bool Function() isCurrent,
  }) async {
    this.credential = credential;
    return super.openOwned(
      request,
      credential: credential,
      binding: binding,
      isCurrent: isCurrent,
    );
  }
}

final class FakeVault implements RdpSchema6SecretVault {
  @override
  Future<RdpOwnedSecretBuffer> resolve({
    required RdpSchema6SecretScope scope,
    required RdpSchema6SecretKind kind,
    required RdpDeviceSecretReference reference,
    required bool Function() isCurrent,
  }) async => RdpOwnedSecretBuffer(Uint8List.fromList([7, 8]));
  @override
  Future<RdpDeviceSecretReference> save({
    required RdpSchema6SecretScope scope,
    required RdpSchema6SecretKind kind,
    required Uint8List secret,
    required bool Function() isCurrent,
  }) => throw UnimplementedError();
  @override
  Future<void> delete({
    required RdpSchema6SecretScope scope,
    required RdpSchema6SecretKind kind,
    required RdpDeviceSecretReference reference,
    required bool Function() isCurrent,
  }) => throw UnimplementedError();
}

void main() {
  test(
    'normal owned authority opens and drains the exact planned owner',
    () async {
      final port = FakeTransferPort();
      final transfer = RdpSchema6TransferCoordinator(
        port: port,
        authority: authority,
        grant: grant,
        isCurrent: () => true,
      );
      final authorityOwner = RdpSchema6SessionAuthority(
        transfer: transfer,
        isCurrent: () => true,
      );
      final gateway = FakeOwnedSessionGateway();
      final request = RdpSessionRequest(
        profile: const RemoteProfile(
          id: '0123456789abcdef0123456789abcdef',
          name: 'Owned RDP',
          protocol: RemoteProtocol.rdp,
          host: 'rdp.example',
          port: 3389,
          username: 'user',
        ),
        display: const RdpDisplaySpec(width: 1280, height: 800),
        certificateFingerprint: pin,
        channels: const RdpChannelPolicy(
          clipboard: false,
          audio: false,
          microphone: false,
          files: true,
        ),
      );
      final channel = await authorityOwner.open(
        gateway: gateway,
        request: request,
        credential: const RdpCredential(password: 'secret'),
        owner: sessionOwner,
      );
      expect(channel, same(gateway.channel));
      expect(gateway.request, same(request));
      expect(gateway.binding!.owner, sessionOwner);
      expect(gateway.binding!.transfer!.state, RdpTransferState.prepared);
      final sealed = await authorityOwner.closeAndDrain();
      expect(sealed.state, RdpTransferState.sealed);
      expect(port.saves, 0);
    },
  );

  test(
    'normal Gateway-only controller uses owned schema6 with no SAF lifecycle',
    () async {
      final runtime = FakeGatewayOnlyRuntime();
      final authorityOwner = RdpSchema6SessionAuthority.gatewayOnly(
        isCurrent: () => true,
      );
      final controller = RdpSessionController(
        profile: const RemoteProfile(
          id: '0123456789abcdef0123456789abcdef',
          name: 'Gateway RDP',
          protocol: RemoteProtocol.rdp,
          host: 'rdp.example',
          port: 3389,
          username: 'target-user',
        ),
        trust: FakeTrust(),
        credentialVault: FakeCredentialVault(),
        engineFactory: () => runtime,
        isCurrent: () => true,
        display: const RdpDisplaySpec(width: 1280, height: 800),
        settings: const RdpProfileSettings(
          domain: 'TARGET',
          gatewayHost: 'gateway.example',
          gatewayPort: 443,
          gatewayUsername: 'gateway-user',
          gatewayDomain: 'EDGE',
        ),
        authoritativeSecurity: RdpCoreSecurityProjection(
          domain: 'TARGET',
          certificateFingerprint: pin,
          gateway: RdpCoreGatewaySecurity(
            endpoint: RdpGatewayEndpoint(
              host: 'gateway.example',
              port: 443,
              username: 'gateway-user',
              domain: 'EDGE',
            ),
            certificateFingerprint: pin,
          ),
        ),
        schema6Authority: authorityOwner,
        schema6OwnerFactory: (revision) => RdpSchema6SessionOwner(
          requestId: '12345678-1234-4234-9234-123456789abc',
          revision: revision,
        ),
        schema6Secrets: FakeCurrentVault(),
        schema6SecretScope: RdpSchema6SecretScope(
          namespaceDigest: ''.padLeft(64, 'a'),
          profileRef: ''.padLeft(64, 'b'),
          profileRevision: 2,
        ),
      );

      await controller.connect();

      expect(controller.phase, RdpSessionPhase.connected);
      expect(runtime.binding?.owner.revision, 1);
      expect(runtime.binding?.transfer, isNull);
      expect(runtime.request?.channels.files, isFalse);
      expect(runtime.request?.settings.gatewayHost, 'gateway.example');
      expect(runtime.credential?.password, 'target-secret');
      expect(runtime.credential?.gatewayPassword, 'gateway-secret');
      expect(authorityOwner.receipt, isNull);
      expect(authorityOwner.successorBlocked, isFalse);
      controller.dispose();
    },
  );

  test(
    'Gateway-only authority releases the exact owner for a reconnect',
    () async {
      final authorityOwner = RdpSchema6SessionAuthority.gatewayOnly(
        isCurrent: () => true,
      );
      final request = RdpSessionRequest(
        profile: const RemoteProfile(
          id: '0123456789abcdef0123456789abcdef',
          name: 'Gateway RDP',
          protocol: RemoteProtocol.rdp,
          host: 'rdp.example',
          port: 3389,
          username: 'target-user',
        ),
        display: const RdpDisplaySpec(width: 1280, height: 800),
        certificateFingerprint: pin,
        gatewayCertificateFingerprint: pin,
        settings: const RdpProfileSettings(
          gatewayHost: 'gateway.example',
          gatewayUsername: 'gateway-user',
        ),
        channels: const RdpChannelPolicy(
          clipboard: false,
          audio: false,
          microphone: false,
          files: false,
        ),
      );
      final first = FakeOwnedSessionGateway();
      await authorityOwner.open(
        gateway: first,
        request: request,
        credential: const RdpCredential(
          password: 'target-secret',
          gatewayPassword: 'gateway-secret',
        ),
        owner: sessionOwner,
      );
      first.channel.close();
      await Future<void>.delayed(Duration.zero);

      final second = FakeOwnedSessionGateway();
      final successor = RdpSchema6SessionOwner(
        requestId: '22345678-1234-4234-9234-123456789abc',
        revision: sessionOwner.revision + 1,
      );
      final channel = await authorityOwner.open(
        gateway: second,
        request: request,
        credential: const RdpCredential(
          password: 'target-secret',
          gatewayPassword: 'gateway-secret',
        ),
        owner: successor,
      );
      expect(channel, same(second.channel));
      expect(second.binding?.owner, successor);
      expect(second.binding?.transfer, isNull);
      authorityOwner.close();
    },
  );

  test(
    'drain seals only and explicit save is sole publish operation',
    () async {
      final port = FakeTransferPort();
      final controller = RdpSchema6TransferCoordinator(
        port: port,
        authority: authority,
        grant: grant,
        isCurrent: () => true,
      );
      await controller.prepare(sessionOwner);
      expect(controller.consumeSessionBinding().toWire(), {
        'schemaVersion': 6,
        'requestId': sessionOwner.requestId,
        'sessionRevision': sessionOwner.revision,
        'fileTransfer': {'transferId': 'fedcba9876543210fedcba9876543210'},
      });
      final sealed = await controller.drain();
      expect(sealed.state, RdpTransferState.sealed);
      expect(port.saves, 0);
      expect(controller.successorBlocked, isTrue);
      final saved = await controller.saveReceived();
      expect(saved.state, RdpTransferState.saved);
      expect(port.saves, 1);
      expect(controller.successorBlocked, isFalse);
    },
  );

  test('drain exception is sticky unknown and blocks successor', () async {
    final port = FakeTransferPort()
      ..drainError = StateError('closed uncertain');
    final controller = RdpSchema6TransferCoordinator(
      port: port,
      authority: authority,
      grant: grant,
      isCurrent: () => true,
    );
    await controller.prepare(sessionOwner);
    controller.consumeSessionBinding();
    await expectLater(controller.drain(), throwsStateError);
    expect(controller.receipt!.state, RdpTransferState.unknown);
    expect(controller.successorBlocked, isTrue);
    await expectLater(
      controller.prepare(
        RdpSchema6SessionOwner(
          requestId: '87654321-4321-4321-8321-cba987654321',
          revision: 10,
        ),
      ),
      throwsA(isA<RdpFailure>().having((value) => value.code, 'code', 'busy')),
    );
    await expectLater(controller.saveReceived(), throwsA(isA<RdpFailure>()));
    expect(port.saves, 0);
  });

  test('same transfer id cannot be bound into a successor session', () async {
    final controller = RdpSchema6TransferCoordinator(
      port: FakeTransferPort(),
      authority: authority,
      grant: grant,
      isCurrent: () => true,
    );
    await controller.prepare(sessionOwner);
    controller.consumeSessionBinding();
    expect(controller.consumeSessionBinding, throwsA(isA<RdpFailure>()));
  });

  test('late prepare is fenced unknown and cannot bind a successor', () async {
    var current = true;
    final port = FakeTransferPort()..prepareGate = Completer<void>();
    final controller = RdpSchema6TransferCoordinator(
      port: port,
      authority: authority,
      grant: grant,
      isCurrent: () => current,
    );
    final pending = controller.prepare(sessionOwner);
    await Future<void>.delayed(Duration.zero);
    current = false;
    port.prepareGate!.complete();
    await expectLater(
      pending,
      throwsA(
        isA<RdpFailure>().having((value) => value.code, 'code', 'retired'),
      ),
    );
    expect(controller.receipt!.state, RdpTransferState.unknown);
    expect(controller.successorBlocked, isTrue);
    expect(controller.consumeSessionBinding, throwsA(isA<RdpFailure>()));
  });

  test('late target inspection retires and its secret is wiped', () async {
    var current = true;
    final engine = FakeGatewayEngine();
    final controller = RdpGatewayEnrollmentCoordinator(
      engine: engine,
      secrets: FakeVault(),
      scope: RdpSchema6SecretScope(
        namespaceDigest: ''.padLeft(64, 'a'),
        profileRef: ''.padLeft(64, 'b'),
        profileRevision: 1,
      ),
      isCurrent: () => current,
    );
    final future = controller.inspectTarget(
      target: RdpGatewayEndpoint(
        host: 'target.example',
        port: 3389,
        username: 'user',
        domain: 'TARGET',
      ),
      gateway: RdpPinnedGatewayEndpoint(
        endpoint: RdpGatewayEndpoint(
          host: 'gateway.example',
          port: 443,
          username: 'gateway-user',
          domain: 'EDGE',
        ),
        fingerprint: pin,
      ),
      gatewaySecret: RdpDeviceSecretReference(
        '0123456789abcdef0123456789abcdef',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    current = false;
    controller.retire();
    engine.targetGate.complete();
    await expectLater(future, throwsA(isA<RdpFailure>()));
    expect(engine.observedSecret, [0, 0]);
    expect(engine.closed, isTrue);
  });
}
