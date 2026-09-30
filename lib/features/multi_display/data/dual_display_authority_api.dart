import '../../server/data/larenor_server_api.dart';
import '../../server/domain/server_models.dart';
import '../domain/dual_display_session.dart';

typedef DualDisplayAuthorityReader =
    Future<DualDisplayAuthorityReading> Function(bool Function() current);

/// Reads the current Core authority without exposing it to the isolated engine.
final class DualDisplayAuthorityApi {
  DualDisplayAuthorityApi(this.api, this.session);

  final LarenorServerApi api;
  final ServerSession session;

  Future<DualDisplayAuthorityReading> read({
    required int lifecycleEpoch,
    required int interactionEpoch,
    required bool Function() current,
  }) async {
    final context = session.context;
    final family = session.sessionFamilyId;
    if (context == null || family == null || !current()) {
      throw const LarenorServerException('cancelled');
    }
    final raw = await api.request(
      'GET',
      '/multi-display/${context.coreId}/${context.homeId}/authority',
      token: session.accessToken,
    );
    if (!current()) throw const LarenorServerException('cancelled');
    final envelope = serverObject(raw);
    if (envelope.length != 3 ||
        envelope['schemaVersion'] != 1 ||
        !envelope.containsKey('authority') ||
        !envelope.containsKey('publicSnapshot')) {
      throw const LarenorServerException('invalid_response');
    }
    final value = serverObject(envelope['authority']);
    const keys = {
      'schemaVersion',
      'coreId',
      'homeId',
      'accountId',
      'accountRevision',
      'homeRevision',
      'sessionFamilyId',
      'routePolicyRevision',
      'allowedSecondaryRoutes',
    };
    if (value.length != keys.length || !value.keys.every(keys.contains)) {
      throw const LarenorServerException('invalid_response');
    }
    final routes = value['allowedSecondaryRoutes'];
    if (value['schemaVersion'] != 1 ||
        value['coreId'] != context.coreId ||
        value['homeId'] != context.homeId ||
        value['accountId'] != session.user.id ||
        value['sessionFamilyId'] != family ||
        value['routePolicyRevision'] != 2 ||
        routes is! List ||
        routes.isEmpty ||
        routes.length > 16 ||
        routes.any((route) => route is! String)) {
      throw const LarenorServerException('invalid_response');
    }
    final allowed = routes.cast<String>().toSet();
    if (allowed.length != routes.length ||
        !const {'core.status'}.containsAll(allowed)) {
      throw const LarenorServerException('invalid_response');
    }
    try {
      final authority = DisplayRouteAuthority(
        accountId: session.user.id,
        accountRevision: _revision(value['accountRevision']),
        homeId: context.homeId,
        homeRevision: _revision(value['homeRevision']),
        sessionFamilyId: family,
        routeRevision: _revision(value['routePolicyRevision']),
        lifecycleEpoch: lifecycleEpoch,
        interactionEpoch: interactionEpoch,
        allowedSecondaryRoutes: allowed,
      );
      final snapshot = _publicSnapshot(envelope['publicSnapshot']);
      return DualDisplayAuthorityReading(
        authority: authority,
        publicSnapshot: snapshot,
      );
    } on ArgumentError {
      throw const LarenorServerException('invalid_response');
    }
  }

  void close() => api.close();

  static int _revision(Object? value) {
    if (value is! int || value < 1 || value > 0x1fffffffffffff) {
      throw const LarenorServerException('invalid_response');
    }
    return value;
  }

  static PublicCoreStatusSnapshot _publicSnapshot(Object? raw) {
    try {
      return PublicCoreStatusSnapshot.fromPublicMessage(raw);
    } on ArgumentError {
      throw const LarenorServerException('invalid_response');
    }
  }
}
