import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../../shared/network/transport_observation.dart';
import '../../health/data/health_monitor.dart';

import 'ha_api_exception.dart';
import 'ha_endpoint.dart';
import 'models/ha_entity.dart';

/// Authenticated Home Assistant REST API. Integration-specific endpoints can
/// use [requestJson]; availability and authorization remain server-controlled.
/// https://developers.home-assistant.io/docs/api/rest/
class HaRestClient {
  HaRestClient({
    required String baseUrl,
    required this.token,
    http.Client? httpClient,
    this.requestTimeout = const Duration(seconds: 30),
    this.observer,
    this.healthSession,
  }) : baseUrl = normalizeHaBaseUrl(baseUrl),
       _client = httpClient ?? http.Client();

  final String baseUrl;
  final String token;
  final Duration requestTimeout;
  final http.Client _client;
  final TransportObserver? observer;
  final HealthSession? healthSession;

  Future<bool> checkConnection() async {
    final result = _object(await getJson('/api/'));
    if (result['message'] != 'API running.') {
      throw HaApiException(
        'The server did not return a Home Assistant API response.',
        code: 'invalid_response',
      );
    }
    return true;
  }

  Future<Map<String, dynamic>> getConfig() async =>
      _object(await getJson('/api/config'));

  Future<List<String>> getComponents() async {
    final value = await getJson('/api/components');
    if (value is! List || value.any((entry) => entry is! String)) {
      _invalidResponse();
    }
    return value.cast<String>();
  }

  /// Includes live service descriptions, field selectors and response support
  /// from installed integrations; never assumes a fixed list of domains.
  Future<List<Map<String, dynamic>>> getServices() async =>
      _objects(await getJson('/api/services'));

  Future<List<Map<String, dynamic>>> getEvents() async =>
      _objects(await getJson('/api/events'));

  Future<List<HaEntity>> getStates() async =>
      _objects(await getJson('/api/states')).map(_entity).toList();

  Future<HaEntity> getState(String entityId) async =>
      _entity(_object(await getJson('/api/states/${haPathSegment(entityId)}')));

  /// Changes the state machine representation, not the physical device. Use a
  /// service action to control a device; these states may be overwritten by
  /// its integration and are not entity-registry configuration.
  Future<HaEntity> setState(
    String entityId,
    String state, {
    Map<String, dynamic>? attributes,
    bool forceUpdate = false,
  }) async => _entity(
    _object(
      await postJson('/api/states/${haPathSegment(entityId)}', {
        'state': state,
        'attributes': ?attributes,
        if (forceUpdate) 'force_update': true,
      }),
    ),
  );

  Future<void> deleteState(String entityId) async {
    await deleteJson('/api/states/${haPathSegment(entityId)}');
  }

  /// Backward-compatible action helper used by native accessory controls.
  Future<void> callService(
    String domain,
    String service, {
    String? entityId,
    Map<String, dynamic>? serviceData,
  }) async {
    await callServiceWithResponse(
      domain,
      service,
      serviceData: {...?serviceData, 'entity_id': ?entityId},
    );
  }

  /// Returns changed states, or {changed_states, service_response} when the
  /// service declares response support and [returnResponse] is requested.
  /// REST target keys are merged into service data (unlike the WS envelope).
  /// Never retries mutations after a timeout: the server may still execute.
  Future<dynamic> callServiceWithResponse(
    String domain,
    String service, {
    Map<String, dynamic>? serviceData,
    Map<String, dynamic>? target,
    bool returnResponse = false,
  }) => requestJson(
    'POST',
    '/api/services/${haPathSegment(domain)}/${haPathSegment(service)}',
    body: {...?serviceData, ...?target},
    // HA checks presence, so ?return_response=false would still request it.
    queryParameters: {if (returnResponse) 'return_response': ''},
  );

  Future<Map<String, dynamic>> fireEvent(
    String eventType, {
    Map<String, dynamic>? eventData,
  }) async => _object(
    await postJson('/api/events/${haPathSegment(eventType)}', eventData),
  );

  Future<String> renderTemplate(
    String template, {
    Map<String, dynamic>? variables,
  }) => requestText(
    'POST',
    '/api/template',
    body: {'template': template, 'variables': ?variables},
  );

  Future<String> getErrorLog() => requestText('GET', '/api/error_log');

  /// HTTP 200 may report result: invalid. Inspect that field and errors.
  Future<Map<String, dynamic>> checkConfig() async =>
      _object(await postJson('/api/config/core/check_config'));

  Future<Map<String, dynamic>> handleIntent(
    String name, {
    Map<String, dynamic>? data,
    String? language,
    String? assistant,
    String? deviceId,
    String? satelliteId,
  }) async => _object(
    await postJson('/api/intent/handle', {
      'name': name,
      'data': ?data,
      'language': ?language,
      'assistant': ?assistant,
      'device_id': ?deviceId,
      'satellite_id': ?satelliteId,
    }),
  );

  /// Recorder history may contain compact entries without entity_id or
  /// attributes, so retain the JSON shape rather than forcing HaEntity.
  Future<List<List<Map<String, dynamic>>>> getHistory({
    DateTime? startTime,
    DateTime? endTime,
    required List<String> entityIds,
    bool minimalResponse = false,
    bool noAttributes = false,
    bool significantChangesOnly = true,
    bool skipInitialState = false,
  }) async {
    _checkRange(startTime, endTime);
    if (entityIds.isEmpty || entityIds.any((id) => id.trim().isEmpty)) {
      throw ArgumentError('Select at least one entity for history.');
    }
    final value = await requestJson(
      'GET',
      '/api/history/period${_timestampPath(startTime)}',
      queryParameters: {
        'filter_entity_id': entityIds.join(','),
        if (endTime != null) 'end_time': endTime.toUtc().toIso8601String(),
        if (minimalResponse) 'minimal_response': '',
        if (noAttributes) 'no_attributes': '',
        if (skipInitialState) 'skip_initial_state': '',
        'significant_changes_only': significantChangesOnly ? '1' : '0',
      },
    );
    if (value is! List) _invalidResponse();
    return value.map(_objects).toList();
  }

  Future<List<Map<String, dynamic>>> getLogbook({
    DateTime? startTime,
    DateTime? endTime,
    String? entityId,
    String? contextId,
    int? period,
  }) async {
    _checkRange(startTime, endTime);
    if (entityId != null && contextId != null) {
      throw ArgumentError('Choose an entity or a context, not both.');
    }
    if (period != null && period <= 0) {
      throw ArgumentError('Period must be positive.');
    }
    return _objects(
      await requestJson(
        'GET',
        '/api/logbook${_timestampPath(startTime)}',
        queryParameters: {
          'entity': ?entityId,
          'context_id': ?contextId,
          if (period != null) 'period': '$period',
          if (endTime != null) 'end_time': endTime.toUtc().toIso8601String(),
        },
      ),
    );
  }

  Future<List<Map<String, dynamic>>> getCalendars() async =>
      _objects(await getJson('/api/calendars'));

  Future<List<Map<String, dynamic>>> getCalendarEvents(
    String entityId, {
    required DateTime start,
    required DateTime end,
  }) async {
    _checkRange(start, end);
    return _objects(
      await requestJson(
        'GET',
        '/api/calendars/${haPathSegment(entityId)}',
        queryParameters: {
          'start': start.toUtc().toIso8601String(),
          'end': end.toUtc().toIso8601String(),
        },
      ),
    );
  }

  Future<Uint8List> getCameraImage(String entityId) =>
      getBytes('/api/camera_proxy/${haPathSegment(entityId)}');

  Future<dynamic> getJson(String path) => requestJson('GET', path);
  Future<dynamic> postJson(String path, [Map<String, dynamic>? body]) =>
      requestJson('POST', path, body: body ?? {});
  Future<dynamic> deleteJson(String path) => requestJson('DELETE', path);

  /// Generic same-server API access for integration-specific HTTP endpoints.
  Future<dynamic> requestJson(
    String method,
    String path, {
    Object? body,
    Map<String, String>? queryParameters,
    Map<String, String>? headers,
  }) async => _decodeJson(
    await _request(
      method,
      path,
      body: body,
      queryParameters: queryParameters,
      headers: headers,
    ),
  );

  Future<String> requestText(
    String method,
    String path, {
    Object? body,
    Map<String, String>? queryParameters,
    Map<String, String>? headers,
  }) async => utf8.decode(
    (await _request(
      method,
      path,
      body: body,
      queryParameters: queryParameters,
      headers: headers,
    )).bodyBytes,
    allowMalformed: true,
  );

  Future<Uint8List> getBytes(String path) async =>
      (await _request('GET', path)).bodyBytes;

  Future<http.Response> _request(
    String method,
    String path, {
    Object? body,
    Map<String, String>? queryParameters,
    Map<String, String>? headers,
  }) async {
    final verb = method.toUpperCase();
    if (!{
      'GET',
      'POST',
      'PUT',
      'PATCH',
      'DELETE',
      'HEAD',
      'OPTIONS',
    }.contains(verb)) {
      throw ArgumentError.value(method, 'method', 'Unsupported HTTP method');
    }
    if (headers?.keys.any(
          (key) => {
            'authorization',
            'cookie',
            'host',
            'proxy-authorization',
          }.contains(key.toLowerCase()),
        ) ==
        true) {
      throw ArgumentError(
        'Authentication and host headers cannot be overridden.',
      );
    }
    final request =
        http.Request(
            verb,
            haApiUri(baseUrl, path, queryParameters: queryParameters),
          )
          // A redirect must not send the bearer token to a different origin.
          ..followRedirects = false
          ..headers.addAll({
            ...?headers,
            'Authorization': 'Bearer $token',
            'Accept': 'application/json',
          });
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final http.Response response;
    final isRead = {'GET', 'HEAD'}.contains(verb);
    try {
      response = await (() async {
        final streamed = await _client.send(request);
        notifyTransport(
          observer,
          TransportObservation(
            kind: TransportObservationKind.response,
            isRead: isRead,
            statusCode: streamed.statusCode,
          ),
        );
        return http.Response.fromStream(streamed);
      })().timeout(requestTimeout);
    } on TimeoutException {
      notifyTransport(
        observer,
        TransportObservation(
          kind: TransportObservationKind.failed,
          isRead: isRead,
          failure: TransportFailure.timeout,
        ),
      );
      throw HaApiException(
        'Home Assistant request timed out.',
        code: 'timeout',
      );
    } on http.ClientException {
      notifyTransport(
        observer,
        TransportObservation(
          kind: TransportObservationKind.failed,
          isRead: isRead,
          failure: TransportFailure.connection,
        ),
      );
      throw HaApiException(
        'Could not reach Home Assistant.',
        code: 'connection_error',
      );
    }
    notifyTransport(
      observer,
      TransportObservation(
        kind: TransportObservationKind.completed,
        isRead: isRead,
        statusCode: response.statusCode,
      ),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HaApiException(
        _errorMessage(response),
        statusCode: response.statusCode,
        code: switch (response.statusCode) {
          401 => 'unauthorized',
          403 => 'forbidden',
          404 => 'not_found',
          _ => 'http_error',
        },
      );
    }
    return response;
  }

  String _errorMessage(http.Response response) {
    final fallback = switch (response.statusCode) {
      401 => 'Invalid or expired access token.',
      403 => 'This account is not allowed to perform that action.',
      _ => 'Home Assistant request failed (${response.statusCode}).',
    };
    try {
      final value = jsonDecode(utf8.decode(response.bodyBytes));
      if (value is Map && value['message'] is String) {
        final message = value['message'] as String;
        return token.isEmpty
            ? message
            : message.replaceAll(token, '[redacted]');
      }
    } on FormatException {
      // HTML proxy errors and token-bearing URLs are not exposed as messages.
    }
    return fallback;
  }

  dynamic _decodeJson(http.Response response) {
    if (response.bodyBytes.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      return _invalidResponse();
    }
  }

  static Never _invalidResponse() => throw HaApiException(
    'Home Assistant returned an invalid response.',
    code: 'invalid_response',
  );
  static Map<String, dynamic> _object(dynamic value) =>
      value is Map<String, dynamic> ? value : _invalidResponse();
  static List<Map<String, dynamic>> _objects(dynamic value) {
    if (value is! List) _invalidResponse();
    return value.map(_object).toList();
  }

  static HaEntity _entity(Map<String, dynamic> value) {
    try {
      return HaEntity.fromJson(value);
    } catch (_) {
      return _invalidResponse();
    }
  }

  static String _timestampPath(DateTime? value) => value == null
      ? ''
      : '/${Uri.encodeComponent(value.toUtc().toIso8601String())}';
  static void _checkRange(DateTime? start, DateTime? end) {
    if (start != null && end != null && !end.isAfter(start)) {
      throw ArgumentError('The end time must be after the start time.');
    }
  }

  void dispose() => _client.close();
}
