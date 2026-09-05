import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/admin/data/admin_client.dart';
import 'package:larenor/features/ha_client/data/rest_client.dart';
import 'package:larenor/features/ha_client/data/ws_client.dart';

class RecordingAdminSocket extends HaWebSocketClient {
  RecordingAdminSocket({this.respond})
    : super(baseUrl: 'http://ha.test', token: 'test-token');
  final FutureOr<dynamic> Function(Map<String, dynamic>)? respond;
  final commands = <Map<String, dynamic>>[];

  @override
  Future<dynamic> sendCommand(
    Map<String, dynamic> command, {
    Duration timeout = const Duration(seconds: 15),
    bool Function()? isCurrent,
  }) async {
    commands.add(Map.of(command));
    return respond == null ? <String, dynamic>{} : await respond!(command);
  }
}

HaAdminClient fakeAdminClient(
  RecordingAdminSocket socket, {
  Future<http.Response> Function(http.Request)? respond,
}) => HaAdminClient(
  HaRestClient(
    baseUrl: 'http://ha.test',
    token: 'test-token',
    httpClient: MockClient(respond ?? (_) async => http.Response('[]', 200)),
  ),
  socket,
);
