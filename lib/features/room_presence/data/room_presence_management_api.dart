import '../domain/room_presence_management_models.dart';
import '../../server/data/larenor_server_api.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';

/// Authenticated Core boundary. Sensor identifiers and provider credentials
/// remain inside Core and never enter this interface.
abstract interface class RoomPresenceManagementApi {
  Future<List<RoomPresenceEvidence>> list(
    RoomPresenceClientAuthority authority,
  );

  Future<PresenceCalibrationPreview> previewCalibration(
    RoomPresenceClientAuthority authority, {
    required String deviceId,
    required String expectedDeviceRevision,
    required String expectedModelRevision,
    required String roomId,
    required String expectedRoomRevision,
    required String expectedPolicyRevision,
    required String expectedConsentRevision,
    required String expectedCalibrationRevision,
  });

  Future<PresenceCalibrationReceipt> confirmCalibration(
    RoomPresenceClientAuthority authority,
    PresenceCalibrationPreview preview,
  );

  Future<RoomPresenceEvidence> readback(
    RoomPresenceClientAuthority authority, {
    required String deviceId,
  });
}

final class CoreRoomPresenceHttpApi implements RoomPresenceManagementApi {
  factory CoreRoomPresenceHttpApi({
    required LarenorServerApi api,
    required String token,
    required ServerContext context,
    required String accountId,
    required String routeId,
    required int sessionRevision,
    required int routeRevision,
    required bool Function() isCurrent,
  }) => CoreRoomPresenceHttpApi._(
    api,
    token,
    context,
    accountId,
    routeId,
    sessionRevision,
    routeRevision,
    isCurrent,
  );

  const CoreRoomPresenceHttpApi._(
    this._api,
    this._token,
    this._context,
    this._accountId,
    this._routeId,
    this._sessionRevision,
    this._routeRevision,
    this._isCurrent,
  );

  final LarenorServerApi _api;
  final String _token;
  final ServerContext _context;
  final String _accountId;
  final String _routeId;
  final int _sessionRevision;
  final int _routeRevision;
  final bool Function() _isCurrent;
  String get _root => '/room-presence/${_context.coreId}/${_context.homeId}';

  void _active() {
    if (!_isCurrent()) throw const LarenorServerException('cancelled');
  }

  Future<T> _guard<T>(Future<T> Function() operation) async {
    _active();
    try {
      final value = await operation();
      _active();
      return value;
    } on FormatException {
      throw const LarenorServerException('invalid_response');
    }
  }

  Future<RoomPresenceClientAuthority> bootstrap() => _guard(() async {
    final value = await _api.request(
      'POST',
      '$_root/scope',
      token: _token,
      body: {
        'schemaVersion': 1,
        'routeId': _routeId,
        'routeRevision': _routeRevision,
        'clientSessionRevision': _sessionRevision,
      },
    );
    return RoomPresenceClientAuthority.fromJson(
      value,
      coreId: _context.coreId,
      homeId: _context.homeId,
      accountId: _accountId,
      routeId: _routeId,
      sessionRevision: _sessionRevision,
      routeRevision: _routeRevision,
    );
  });

  @override
  Future<List<RoomPresenceEvidence>> list(
    RoomPresenceClientAuthority authority,
  ) => _guard(() async {
    final raw = await _api.request(
      'POST',
      '$_root/devices/query',
      token: _token,
      body: {'schemaVersion': 1, 'authority': authority.toJson()},
    );
    if (raw == null ||
        raw.length != 3 ||
        raw['schemaVersion'] != 1 ||
        raw['authority'] is! Map ||
        raw['devices'] is! List) {
      throw const FormatException('invalid room presence page');
    }
    final returned = RoomPresenceClientAuthority.fromJson(
      raw['authority'],
      coreId: authority.coreId,
      homeId: authority.homeId,
      accountId: authority.accountId,
      routeId: authority.routeId,
      sessionRevision: authority.sessionRevision,
      routeRevision: authority.routeRevision,
    );
    if (returned != authority || (raw['devices'] as List).length > 100) {
      throw const FormatException('foreign room presence page');
    }
    return (raw['devices'] as List)
        .map((value) => RoomPresenceEvidence.fromJson(value, authority))
        .toList(growable: false);
  });

  @override
  Future<PresenceCalibrationPreview> previewCalibration(
    RoomPresenceClientAuthority authority, {
    required String deviceId,
    required String expectedDeviceRevision,
    required String expectedModelRevision,
    required String roomId,
    required String expectedRoomRevision,
    required String expectedPolicyRevision,
    required String expectedConsentRevision,
    required String expectedCalibrationRevision,
  }) => _guard(
    () async => PresenceCalibrationPreview.fromJson(
      await _api.request(
        'POST',
        '$_root/devices/$deviceId/calibration/preview',
        token: _token,
        body: {
          'schemaVersion': 1,
          'authority': authority.toJson(),
          'deviceId': deviceId,
          'expectedDeviceRevision': int.parse(expectedDeviceRevision),
          'expectedModelRevision': int.parse(expectedModelRevision),
          'roomId': roomId,
          'expectedRoomRevision': int.parse(expectedRoomRevision),
          'expectedPolicyRevision': int.parse(expectedPolicyRevision),
          'expectedConsentRevision': int.parse(expectedConsentRevision),
          'expectedCalibrationRevision': int.parse(expectedCalibrationRevision),
        },
      ),
      authority,
    ),
  );

  @override
  Future<PresenceCalibrationReceipt> confirmCalibration(
    RoomPresenceClientAuthority authority,
    PresenceCalibrationPreview preview,
  ) => _guard(
    () async => PresenceCalibrationReceipt.fromJson(
      await _api.request(
        'POST',
        '$_root/calibrations/${preview.requestId}/confirm',
        token: _token,
        body: preview.toJson(),
      ),
      authority,
    ),
  );

  @override
  Future<RoomPresenceEvidence> readback(
    RoomPresenceClientAuthority authority, {
    required String deviceId,
  }) => _guard(
    () async => RoomPresenceEvidence.fromJson(
      await _api.request(
        'POST',
        '$_root/devices/$deviceId/readback',
        token: _token,
        body: {'schemaVersion': 1, 'authority': authority.toJson()},
      ),
      authority,
    ),
  );
}

/// One route-owned Core transport. It revalidates the account and the signed
/// server authority before every operation, and never stores a token itself.
final class RoomPresenceAccountGateway implements RoomPresenceManagementApi {
  RoomPresenceAccountGateway({
    required this.account,
    required this.context,
    required this.routeId,
    required this.routeRevision,
    required this.isCurrent,
    ServerApiFactory? apiFactory,
  }) : _generation = account.generation,
       _sessionRevision = account.generation < 1 ? 1 : account.generation,
       _endpoint = account.session!.endpoint,
       _api =
           (apiFactory ?? ((endpoint) => LarenorServerApi(endpoint: endpoint)))(
             account.session!.endpoint,
           );

  final ServerAccountController account;
  final ServerContext context;
  final String routeId;
  final int routeRevision;
  final bool Function() isCurrent;
  final int _generation;
  final int _sessionRevision;
  final ServerEndpoint _endpoint;
  final LarenorServerApi _api;
  bool _closed = false;

  Future<CoreRoomPresenceHttpApi> _client() async {
    if (_closed || !isCurrent() || !account.isCurrent(_generation)) {
      throw const LarenorServerException('cancelled');
    }
    final session = await account.ensureSession();
    if (_closed ||
        !isCurrent() ||
        !account.isCurrent(_generation) ||
        session.context != context ||
        session.endpoint.baseUrl != _endpoint.baseUrl ||
        session.user.mustChangePassword) {
      throw const LarenorServerException('cancelled');
    }
    return CoreRoomPresenceHttpApi(
      api: _api,
      token: session.accessToken,
      context: context,
      accountId: session.user.id,
      routeId: routeId,
      sessionRevision: _sessionRevision,
      routeRevision: routeRevision,
      isCurrent: isCurrent,
    );
  }

  Future<RoomPresenceClientAuthority> bootstrap() async =>
      (await _client()).bootstrap();

  Future<CoreRoomPresenceHttpApi> _authorized(
    RoomPresenceClientAuthority authority,
  ) async {
    final client = await _client();
    if (await client.bootstrap() != authority) {
      throw const LarenorServerException('revision_conflict');
    }
    return client;
  }

  @override
  Future<List<RoomPresenceEvidence>> list(
    RoomPresenceClientAuthority authority,
  ) async => (await _authorized(authority)).list(authority);

  @override
  Future<PresenceCalibrationPreview> previewCalibration(
    RoomPresenceClientAuthority authority, {
    required String deviceId,
    required String expectedDeviceRevision,
    required String expectedModelRevision,
    required String roomId,
    required String expectedRoomRevision,
    required String expectedPolicyRevision,
    required String expectedConsentRevision,
    required String expectedCalibrationRevision,
  }) async => (await _authorized(authority)).previewCalibration(
    authority,
    deviceId: deviceId,
    expectedDeviceRevision: expectedDeviceRevision,
    expectedModelRevision: expectedModelRevision,
    roomId: roomId,
    expectedRoomRevision: expectedRoomRevision,
    expectedPolicyRevision: expectedPolicyRevision,
    expectedConsentRevision: expectedConsentRevision,
    expectedCalibrationRevision: expectedCalibrationRevision,
  );

  @override
  Future<PresenceCalibrationReceipt> confirmCalibration(
    RoomPresenceClientAuthority authority,
    PresenceCalibrationPreview preview,
  ) async =>
      (await _authorized(authority)).confirmCalibration(authority, preview);

  @override
  Future<RoomPresenceEvidence> readback(
    RoomPresenceClientAuthority authority, {
    required String deviceId,
  }) async =>
      (await _authorized(authority)).readback(authority, deviceId: deviceId);

  void close() {
    if (_closed) return;
    _closed = true;
    _api.close();
  }
}
