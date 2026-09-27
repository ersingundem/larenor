import '../../server/data/larenor_server_api.dart';
import '../../server/domain/server_models.dart';
import '../domain/local_notification_models.dart';

final class LocalNotificationApi {
  LocalNotificationApi(
    this._api,
    this._session, {
    required bool Function() isCurrent,
  }) : _current = isCurrent;
  final LarenorServerApi _api;
  final ServerSession _session;
  final bool Function() _current;
  bool _retired = false;

  ServerContext get _context => _session.context!;
  String get _root =>
      '/local-notifications/${_context.coreId}/${_context.homeId}';

  void retire() => _retired = true;
  void _check() {
    try {
      if (!_retired && _current()) return;
    } catch (_) {}
    _retired = true;
    throw const LarenorServerException('cancelled');
  }

  Future<T> _operation<T>(Future<T> Function() action) async {
    _check();
    try {
      final value = await action();
      _check();
      return value;
    } catch (_) {
      _check();
      rethrow;
    }
  }

  Future<LocalNotificationSubscription> register({
    required String id,
    required DateTime expiresAt,
  }) => _operation(() async {
    final body = await _api.request(
      'POST',
      '$_root/subscriptions',
      token: _session.accessToken,
      body: {
        'schemaVersion': 1,
        'registrationId': id,
        'permission': 'granted',
        'expiresAt': expiresAt.toUtc().millisecondsSinceEpoch / 1000,
      },
    );
    _check();
    return LocalNotificationSubscription.fromJson(
      body,
      context: _context,
      expectedId: id,
    );
  });

  Future<LocalNotificationSubscription> renew(
    LocalNotificationSubscription before, {
    required DateTime expiresAt,
  }) => _operation(() async {
    final body = await _api.request(
      'PUT',
      '$_root/subscriptions/${before.id}',
      token: _session.accessToken,
      body: {
        'schemaVersion': 1,
        'expectedRevision': before.revision,
        'permission': 'granted',
        'expiresAt': expiresAt.toUtc().millisecondsSinceEpoch / 1000,
      },
    );
    _check();
    final next = LocalNotificationSubscription.fromJson(
      body,
      context: _context,
      expectedId: before.id,
    );
    if (next.revision != before.revision + 1) {
      throw const LarenorServerException('invalid_response');
    }
    return next;
  });

  Future<LocalNotificationDeliveryLease> registerDeliveryLease(
    LocalNotificationSubscription subscription,
    LocalNotificationDeliveryRegistration registration,
  ) => _operation(() async {
    if (registration.expectedSubscriptionRevision != subscription.revision) {
      throw const LarenorServerException('invalid_request');
    }
    final body = await _api.request(
      'POST',
      '$_root/subscriptions/${subscription.id}/delivery-leases',
      token: _session.accessToken,
      body: {
        'schemaVersion': 1,
        'leaseId': registration.leaseId,
        'credential': registration.credential,
        'credentialFingerprint': registration.credentialFingerprint,
        'expectedSubscriptionRevision': subscription.revision,
        'expiresAt':
            registration.expiresAt.toUtc().millisecondsSinceEpoch / 1000,
      },
    );
    _check();
    return LocalNotificationDeliveryLease.fromJson(
      body,
      context: _context,
      expectedId: registration.leaseId,
      expectedSubscriptionId: subscription.id,
      expectedCredentialFingerprint: registration.credentialFingerprint,
    );
  });

  Future<LocalNotificationDeliveryLease> getDeliveryLease({
    required String leaseId,
    required String subscriptionId,
    required String credentialFingerprint,
  }) => _operation(() async {
    final body = await _api.request(
      'GET',
      '$_root/delivery-leases/$leaseId',
      token: _session.accessToken,
      queryParameters: {'credentialFingerprint': credentialFingerprint},
    );
    _check();
    return LocalNotificationDeliveryLease.fromJson(
      body,
      context: _context,
      expectedId: leaseId,
      expectedSubscriptionId: subscriptionId,
      expectedCredentialFingerprint: credentialFingerprint,
    );
  });

  Future<LocalNotificationDeliveryLease> renewDeliveryLease(
    LocalNotificationDeliveryLease before,
    LocalNotificationSubscription subscription, {
    required DateTime expiresAt,
  }) => _operation(() async {
    if (before.context != _context ||
        before.subscriptionId != subscription.id ||
        before.state != LocalNotificationDeliveryLeaseState.active) {
      throw const LarenorServerException('invalid_request');
    }
    final body = await _api.request(
      'PUT',
      '$_root/delivery-leases/${before.id}',
      token: _session.accessToken,
      body: {
        'schemaVersion': 1,
        'expectedRevision': before.revision,
        'expectedSubscriptionRevision': subscription.revision,
        'expiresAt': expiresAt.toUtc().millisecondsSinceEpoch / 1000,
      },
    );
    _check();
    final next = LocalNotificationDeliveryLease.fromJson(
      body,
      context: _context,
      expectedId: before.id,
      expectedSubscriptionId: subscription.id,
      expectedCredentialFingerprint: before.credentialFingerprint,
    );
    if (next.state != LocalNotificationDeliveryLeaseState.active ||
        next.revision != before.revision + 1 ||
        next.subscriptionRevision != subscription.revision) {
      throw const LarenorServerException('invalid_response');
    }
    return next;
  });

  Future<void> revokeDeliveryLease(LocalNotificationDeliveryLease before) =>
      _operation(() async {
        if (before.context != _context ||
            before.state != LocalNotificationDeliveryLeaseState.active) {
          throw const LarenorServerException('invalid_request');
        }
        await _api.request(
          'DELETE',
          '$_root/delivery-leases/${before.id}',
          token: _session.accessToken,
          queryParameters: {'expectedRevision': '${before.revision}'},
          allowEmpty: true,
        );
      });

  Future<LocalNotificationPage> pull(
    LocalNotificationSubscription subscription, {
    int after = 0,
    int limit = 50,
  }) => _operation(() async {
    if (after < 0 || limit < 1 || limit > 100) {
      throw const LarenorServerException('invalid_request');
    }
    final body = await _api.request(
      'GET',
      '$_root/subscriptions/${subscription.id}/events',
      token: _session.accessToken,
      queryParameters: {
        'expectedRevision': '${subscription.revision}',
        if (after > 0) 'after': '$after',
        'limit': '$limit',
      },
    );
    _check();
    return LocalNotificationPage.fromJson(
      body,
      context: _context,
      expectedRevision: subscription.revision,
      after: after,
    );
  });

  Future<void> acknowledge(
    LocalNotificationSubscription subscription,
    LocalNotificationEvent event,
  ) => _operation(() async {
    final body = await _api.request(
      'POST',
      '$_root/subscriptions/${subscription.id}/acknowledgements',
      token: _session.accessToken,
      body: {
        'schemaVersion': 1,
        'expectedSubscriptionRevision': subscription.revision,
        'sequences': [event.sequence],
      },
    );
    _check();
    if (body == null ||
        body.length != 3 ||
        body['schemaVersion'] != 1 ||
        body['subscriptionRevision'] != subscription.revision ||
        body['acknowledgedThrough'] != event.sequence) {
      throw const LarenorServerException('invalid_response');
    }
  });

  @override
  String toString() => 'LocalNotificationApi';
}
