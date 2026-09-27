import '../../server/domain/server_models.dart';

Never _invalid() => throw const LarenorServerException('invalid_response');

Map<String, dynamic> _closed(Object? value, Set<String> keys) {
  final map = serverObject(value);
  if (map.length != keys.length || map.keys.any((key) => !keys.contains(key))) {
    _invalid();
  }
  return map;
}

String _text(Object? value, int maximum, {bool empty = false}) {
  if (value is! String ||
      value.length > maximum ||
      (!empty && value.isEmpty) ||
      value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
    _invalid();
  }
  return value;
}

String _identity(Object? value) {
  final text = _text(value, 32);
  if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(text)) _invalid();
  return text;
}

int _positive(Object? value) {
  if (value is! int || value < 1 || value > 0x7fffffffffffffff) _invalid();
  return value;
}

DateTime _time(Object? value) {
  if (value is! num || !value.isFinite) _invalid();
  return DateTime.fromMillisecondsSinceEpoch(
    (value * 1000).round(),
    isUtc: true,
  );
}

enum LocalNotificationSensitivity { public, private }

enum LocalNotificationDelivery { available, delivered }

enum LocalNotificationReadState { unread, read }

enum LocalNotificationPermission { denied, inAppOnly, systemAllowed }

enum LocalNotificationDeliveryLeaseState { active, revoked, expired }

final class LocalNotificationProjection {
  const LocalNotificationProjection({
    required this.title,
    required this.body,
    required this.target,
    required this.redacted,
  });
  factory LocalNotificationProjection.fromJson(Object? json) {
    final value = _closed(json, {'title', 'body', 'target', 'redacted'});
    if (value['redacted'] is! bool ||
        value['target'] != null && value['target'] is! String) {
      _invalid();
    }
    final projection = LocalNotificationProjection(
      title: _text(value['title'], 120),
      body: _text(value['body'], 1024, empty: true),
      target: value['target'] == null ? null : _safeTarget(value['target']),
      redacted: value['redacted'] as bool,
    );
    if (projection.redacted &&
        (projection.title != 'Larenor' ||
            projection.body.isNotEmpty ||
            projection.target != null)) {
      _invalid();
    }
    return projection;
  }
  final String title, body;
  final String? target;
  final bool redacted;
}

String _safeTarget(Object? raw) {
  final value = _text(raw, 256);
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !value.startsWith('/') ||
      value.startsWith('//') ||
      uri.hasScheme ||
      uri.hasAuthority ||
      uri.hasQuery ||
      uri.hasFragment ||
      value.contains('\\') ||
      uri.pathSegments.any(
        (part) => part.isEmpty || part == '.' || part == '..',
      )) {
    _invalid();
  }
  return value;
}

final class LocalNotificationEvent {
  const LocalNotificationEvent({
    required this.id,
    required this.sequence,
    required this.category,
    required this.sensitivity,
    required this.title,
    required this.body,
    required this.target,
    required this.createdAt,
    required this.delivery,
    required this.readState,
    required this.projection,
  });
  factory LocalNotificationEvent.fromJson(Object? json) {
    final value = _closed(json, {
      'schemaVersion',
      'id',
      'sequence',
      'category',
      'sensitivity',
      'title',
      'body',
      'target',
      'createdAt',
      'deliveryState',
      'readState',
      'acknowledged',
      'publicProjection',
    });
    if (value['schemaVersion'] != 1 || value['acknowledged'] is! bool) {
      _invalid();
    }
    final sensitivity = switch (value['sensitivity']) {
      'public' => LocalNotificationSensitivity.public,
      'private' => LocalNotificationSensitivity.private,
      _ => _invalid(),
    };
    final delivery = switch (value['deliveryState']) {
      'available' => LocalNotificationDelivery.available,
      'delivered' => LocalNotificationDelivery.delivered,
      _ => _invalid(),
    };
    final readState = switch (value['readState']) {
      'unread' => LocalNotificationReadState.unread,
      'read' => LocalNotificationReadState.read,
      _ => _invalid(),
    };
    if ((value['acknowledged'] as bool) !=
        (readState == LocalNotificationReadState.read)) {
      _invalid();
    }
    final projection = LocalNotificationProjection.fromJson(
      value['publicProjection'],
    );
    if (sensitivity == LocalNotificationSensitivity.private &&
            !projection.redacted ||
        sensitivity == LocalNotificationSensitivity.public &&
            projection.redacted) {
      _invalid();
    }
    return LocalNotificationEvent(
      id: _identity(value['id']),
      sequence: _positive(value['sequence']),
      category: _text(value['category'], 64),
      sensitivity: sensitivity,
      title: _text(value['title'], 120),
      body: _text(value['body'], 1024),
      target: _safeTarget(value['target']),
      createdAt: _time(value['createdAt']),
      delivery: delivery,
      readState: readState,
      projection: projection,
    );
  }
  final String id, category, title, body, target;
  final int sequence;
  final DateTime createdAt;
  final LocalNotificationSensitivity sensitivity;
  final LocalNotificationDelivery delivery;
  final LocalNotificationReadState readState;
  final LocalNotificationProjection projection;

  LocalNotificationEvent asRead() => LocalNotificationEvent(
    id: id,
    sequence: sequence,
    category: category,
    sensitivity: sensitivity,
    title: title,
    body: body,
    target: target,
    createdAt: createdAt,
    delivery: delivery,
    readState: LocalNotificationReadState.read,
    projection: projection,
  );

  bool sameEnvelope(LocalNotificationEvent other) =>
      id == other.id &&
      sequence == other.sequence &&
      category == other.category &&
      sensitivity == other.sensitivity &&
      title == other.title &&
      body == other.body &&
      target == other.target &&
      createdAt == other.createdAt &&
      projection.title == other.projection.title &&
      projection.body == other.projection.body &&
      projection.target == other.projection.target &&
      projection.redacted == other.projection.redacted;
}

final class LocalNotificationSubscription {
  const LocalNotificationSubscription({
    required this.id,
    required this.revision,
    required this.permission,
    required this.expiresAt,
  });
  factory LocalNotificationSubscription.fromJson(
    Object? json, {
    required ServerContext context,
    required String expectedId,
  }) {
    final wrapper = _closed(json, {'subscription'});
    final value = _closed(wrapper['subscription'], {
      'schemaVersion',
      'ref',
      'revision',
      'permission',
      'state',
      'expiresAt',
    });
    final ref = _closed(value['ref'], {
      'schemaVersion',
      'coreId',
      'homeId',
      'kind',
      'id',
    });
    if (value['schemaVersion'] != 1 ||
        ref['schemaVersion'] != 1 ||
        ref['coreId'] != context.coreId ||
        ref['homeId'] != context.homeId ||
        ref['kind'] != 'local_notification_subscription' ||
        ref['id'] != expectedId ||
        value['state'] != 'active') {
      _invalid();
    }
    final permission = switch (value['permission']) {
      'granted' => LocalNotificationPermission.inAppOnly,
      'denied' => LocalNotificationPermission.denied,
      _ => _invalid(),
    };
    return LocalNotificationSubscription(
      id: _identity(ref['id']),
      revision: _positive(value['revision']),
      permission: permission,
      expiresAt: _time(value['expiresAt']),
    );
  }
  final String id;
  final int revision;
  final LocalNotificationPermission permission;
  final DateTime expiresAt;
}

/// One opaque native-generated delivery authority. The credential crosses
/// Dart only long enough to register the lease and is deliberately redacted
/// from diagnostics.
final class LocalNotificationDeliveryRegistration {
  const LocalNotificationDeliveryRegistration._({
    required this.leaseId,
    required this.credential,
    required this.credentialFingerprint,
    required this.expectedSubscriptionRevision,
    required this.expiresAt,
  });

  factory LocalNotificationDeliveryRegistration.fromJson(Object? json) {
    final value = _closed(json, {
      'schemaVersion',
      'leaseId',
      'credential',
      'credentialFingerprint',
      'expectedSubscriptionRevision',
      'expiresAt',
    });
    final credential = value['credential'];
    final fingerprint = value['credentialFingerprint'];
    final rawExpiry = value['expiresAt'];
    if (value['schemaVersion'] != 1 ||
        credential is! String ||
        credential.length != 43 ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(credential) ||
        fingerprint is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint) ||
        rawExpiry is! num ||
        !rawExpiry.isFinite ||
        rawExpiry <= 0) {
      _invalid();
    }
    return LocalNotificationDeliveryRegistration._(
      leaseId: _identity(value['leaseId']),
      credential: credential,
      credentialFingerprint: fingerprint,
      expectedSubscriptionRevision: _positive(
        value['expectedSubscriptionRevision'],
      ),
      expiresAt: _time(rawExpiry),
    );
  }

  final String leaseId, credential, credentialFingerprint;
  final int expectedSubscriptionRevision;
  final DateTime expiresAt;

  @override
  String toString() => 'LocalNotificationDeliveryRegistration(<redacted>)';
}

final class LocalNotificationDeliveryLease {
  const LocalNotificationDeliveryLease._({
    required this.context,
    required this.id,
    required this.subscriptionId,
    required this.subscriptionRevision,
    required this.revision,
    required this.credentialFingerprint,
    required this.state,
    required this.expiresAt,
  });

  factory LocalNotificationDeliveryLease.fromJson(
    Object? json, {
    required ServerContext context,
    required String expectedId,
    required String expectedSubscriptionId,
    required String expectedCredentialFingerprint,
  }) {
    final wrapper = _closed(json, {'lease'});
    final value = _closed(wrapper['lease'], {
      'schemaVersion',
      'ref',
      'subscriptionId',
      'subscriptionRevision',
      'revision',
      'credentialFingerprint',
      'state',
      'expiresAt',
    });
    final ref = _closed(value['ref'], {
      'schemaVersion',
      'coreId',
      'homeId',
      'kind',
      'id',
    });
    final state = switch (value['state']) {
      'active' => LocalNotificationDeliveryLeaseState.active,
      'revoked' => LocalNotificationDeliveryLeaseState.revoked,
      'expired' => LocalNotificationDeliveryLeaseState.expired,
      _ => _invalid(),
    };
    final fingerprint = value['credentialFingerprint'];
    final rawExpiry = value['expiresAt'];
    if (value['schemaVersion'] != 1 ||
        ref['schemaVersion'] != 1 ||
        ref['coreId'] != context.coreId ||
        ref['homeId'] != context.homeId ||
        ref['kind'] != 'local_notification_delivery_lease' ||
        ref['id'] != expectedId ||
        value['subscriptionId'] != expectedSubscriptionId ||
        fingerprint != expectedCredentialFingerprint ||
        fingerprint is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint) ||
        rawExpiry is! num ||
        !rawExpiry.isFinite ||
        rawExpiry <= 0) {
      _invalid();
    }
    return LocalNotificationDeliveryLease._(
      context: context,
      id: _identity(ref['id']),
      subscriptionId: _identity(value['subscriptionId']),
      subscriptionRevision: _positive(value['subscriptionRevision']),
      revision: _positive(value['revision']),
      credentialFingerprint: fingerprint,
      state: state,
      expiresAt: _time(rawExpiry),
    );
  }

  final ServerContext context;
  final String id, subscriptionId, credentialFingerprint;
  final int subscriptionRevision, revision;
  final LocalNotificationDeliveryLeaseState state;
  final DateTime expiresAt;

  @override
  String toString() => 'LocalNotificationDeliveryLease';
}

final class LocalNotificationPage {
  const LocalNotificationPage({
    required this.events,
    required this.nextAfter,
    required this.subscriptionRevision,
  });
  factory LocalNotificationPage.fromJson(
    Object? json, {
    required ServerContext context,
    required int expectedRevision,
    required int after,
  }) {
    final value = _closed(json, {
      'schemaVersion',
      'scope',
      'subscriptionRevision',
      'events',
      'nextAfter',
    });
    final scope = ServerContext.fromJson(value['scope']);
    final raw = value['events'];
    if (value['schemaVersion'] != 1 ||
        scope != context ||
        value['subscriptionRevision'] != expectedRevision ||
        raw is! List ||
        raw.length > 100) {
      _invalid();
    }
    final events = raw
        .map(LocalNotificationEvent.fromJson)
        .toList(growable: false);
    var previous = after;
    final ids = <String>{};
    for (final event in events) {
      if (event.sequence <= previous || !ids.add(event.id)) {
        _invalid();
      }
      previous = event.sequence;
    }
    final next = value['nextAfter'];
    if (next != null &&
        (next is! int || events.isEmpty || next != events.last.sequence)) {
      _invalid();
    }
    return LocalNotificationPage(
      events: events,
      nextAfter: next as int?,
      subscriptionRevision: expectedRevision,
    );
  }
  final List<LocalNotificationEvent> events;
  final int? nextAfter;
  final int subscriptionRevision;
}

abstract final class LocalNotificationRoutePolicy {
  static String? allowed(String target) {
    if (target == '/') return target;
    try {
      _safeTarget(target);
    } catch (_) {
      return null;
    }
    const roots = {
      '/',
      '/today',
      '/media',
      '/routines',
      '/system',
      '/settings',
      '/wellbeing',
      '/inventory',
      '/workflows',
    };
    if (roots.contains(target)) return target;
    if (target.startsWith('/media/') ||
        target.startsWith('/system/') ||
        target.startsWith('/settings/') ||
        target.startsWith('/entities/')) {
      return target;
    }
    return null;
  }
}
