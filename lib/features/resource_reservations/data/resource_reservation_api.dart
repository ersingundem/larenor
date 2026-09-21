import 'dart:async';

import '../../server/data/larenor_server_api.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../domain/resource_reservation_models.dart';

/// Exact account/session-bound F40 transport. It never retries commands.
final class ResourceReservationAccountApi implements ResourceReservationApi {
  ResourceReservationAccountApi._(
    this.account,
    this.context,
    this.isCurrent,
    this._generation,
    this._endpoint,
    this._api,
    ResourceReservationBootstrap bootstrap,
  ) : authority = bootstrap.authority,
      _calendarRevision = bootstrap.calendarRevision;

  final ServerAccountController account;
  final ServerContext context;
  final bool Function() isCurrent;
  final int _generation;
  final ServerEndpoint _endpoint;
  final LarenorServerApi _api;
  final ResourceReservationAuthority authority;
  int _calendarRevision;
  bool _closed = false;

  static Future<ResourceReservationAccountApi> connect({
    required ServerAccountController account,
    required ServerContext context,
    required String routeId,
    required bool Function() isCurrent,
    ServerApiFactory? apiFactory,
  }) async {
    final generation = account.generation;
    final captured = account.session;
    if (captured == null || captured.context != context || !isCurrent()) {
      throw const ReservationApiException('authority_changed');
    }
    final api =
        (apiFactory ?? ((endpoint) => LarenorServerApi(endpoint: endpoint)))(
          captured.endpoint,
        );
    try {
      final session = await account.ensureSession();
      if (!isCurrent() ||
          !account.isCurrent(generation) ||
          session.context != context ||
          session.endpoint.baseUrl != captured.endpoint.baseUrl) {
        throw const ReservationApiException('authority_changed');
      }
      final raw = await api.request(
        'GET',
        '/resource-reservations/${context.coreId}/${context.homeId}/authority',
        token: session.accessToken,
      );
      if (!isCurrent() ||
          !account.isCurrent(generation) ||
          account.session?.context != context) {
        throw const ReservationApiException('authority_changed');
      }
      final bootstrap = ResourceReservationBootstrap.fromJson(
        raw,
        routeId: routeId,
        coreId: context.coreId,
        homeId: context.homeId,
        accountId: session.user.id,
      );
      return ResourceReservationAccountApi._(
        account,
        context,
        isCurrent,
        generation,
        captured.endpoint,
        api,
        bootstrap,
      );
    } catch (_) {
      api.close();
      rethrow;
    }
  }

  String get _root =>
      '/resource-reservations/${context.coreId}/${context.homeId}/${authority.resourceId}';

  Future<ServerSession> _session() async {
    if (_closed || !isCurrent() || !account.isCurrent(_generation)) {
      throw const ReservationApiException('authority_changed');
    }
    final session = await account.ensureSession();
    if (_closed ||
        !isCurrent() ||
        !account.isCurrent(_generation) ||
        session.context != context ||
        session.endpoint.baseUrl != _endpoint.baseUrl ||
        session.user.id != authority.accountId) {
      throw const ReservationApiException('authority_changed');
    }
    return session;
  }

  Map<String, Object> _expect(int revision) => authority.expectations(revision);

  Future<Map<String, dynamic>?> _request(
    String path,
    Map<String, Object> body, {
    bool empty = false,
  }) async {
    try {
      final session = await _session();
      final value = await _api.request(
        'POST',
        path,
        token: session.accessToken,
        body: body,
        allowEmpty: empty,
      );
      await _session();
      return value;
    } on LarenorServerException catch (error) {
      if (const {
        'connection_failed',
        'timeout',
        'server_unavailable',
      }.contains(error.code)) {
        throw TimeoutException(error.code);
      }
      throw ReservationApiException(error.code);
    }
  }

  @override
  Future<ReservationSnapshot> snapshot(
    ResourceReservationAuthority expected,
  ) async {
    _authority(expected);
    final value = ReservationSnapshot.fromJson(
      await _request('$_root/snapshot', _expect(_calendarRevision)),
      authority,
    );
    _calendarRevision = value.calendarRevision;
    return value;
  }

  @override
  Future<ReservationReceipt> create(
    ResourceReservationAuthority expected, {
    required int expectedCalendarRevision,
    required String commandId,
    required ReservationDraft draft,
  }) async {
    _authority(expected);
    final value = ReservationReceipt.fromJson(
      await _request('$_root/commands/create', {
        ..._expect(expectedCalendarRevision),
        'commandId': commandId,
        ...draft.toJson(),
      }),
      authority,
    );
    _calendarRevision = value.calendarRevision;
    return value;
  }

  @override
  Future<ReservationReceipt> cancel(
    ResourceReservationAuthority expected, {
    required int expectedCalendarRevision,
    required String commandId,
    required String reservationId,
  }) async {
    _authority(expected);
    final value = ReservationReceipt.fromJson(
      await _request('$_root/commands/cancel', {
        ..._expect(expectedCalendarRevision),
        'commandId': commandId,
        'reservationId': reservationId,
      }),
      authority,
    );
    _calendarRevision = value.calendarRevision;
    return value;
  }

  @override
  Future<ReservationReceipt?> receipt(
    ResourceReservationAuthority expected,
    String commandId,
  ) async {
    _authority(expected);
    final value = await _request(
      '$_root/receipts/$commandId',
      _expect(_calendarRevision),
      empty: true,
    );
    if (value == null) return null;
    final receipt = ReservationReceipt.fromJson(value, authority);
    _calendarRevision = receipt.calendarRevision;
    return receipt;
  }

  @override
  Future<ReservationExport> export(
    ResourceReservationAuthority expected, {
    required int expectedCalendarRevision,
    required int limit,
  }) async {
    _authority(expected);
    final value = ReservationExport.fromJson(
      await _request('$_root/export', {
        ..._expect(expectedCalendarRevision),
        'limit': limit,
      }),
      authority,
    );
    _calendarRevision = value.calendarRevision;
    return value;
  }

  void _authority(ResourceReservationAuthority expected) {
    if (expected != authority) {
      throw const ReservationApiException('authority_changed');
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _api.close();
  }
}
