import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

void main() {
  const jobs = '/admin/plugins/jobs';
  final events = '$jobs/${'a' * 32}/events';
  test('job cursors are canonical and restricted to exact read routes', () async {
    var calls = 0;
    final api = LarenorServerApi(endpoint: ServerEndpoint('https://server.test/prefix'),
      client: MockClient((request) async { calls++; return http.Response('{}',200,headers:{'content-type':'application/json'}); }));
    await api.request('GET',jobs,queryParameters:{'before':'5','limit':'25'});
    await api.request('GET',events,queryParameters:{'after':'0','limit':'100'});
    expect(calls,2);
    for (final entry in [
      (jobs, {'after':'0'}), (events, {'before':'1'}),
      (jobs, {'before':'0'}), (jobs, {'before':'01'}),
      (jobs, {'before':'9223372036854775808'}),
      (events, {'after':'-1'}), (events, {'limit':'101'}),
      (events, {'limit':'0'}), (events, {'after':'0','userId':'x'}),
      ('/auth/me', {'after':'0'}), (jobs+'/capabilities', {'limit':'1'}),
    ]) {
      await expectLater(api.request('GET',entry.$1,queryParameters:entry.$2),
        throwsA(isA<LarenorServerException>().having((e)=>e.code,'code','invalid_request')));
    }
    await expectLater(api.request('POST',jobs,queryParameters:{'before':'2'}),throwsA(isA<LarenorServerException>()));
    expect(calls,2); api.close();
  });
  test('only known job errors with matching HTTP status pass through', () async {
    for (final entry in {'plugin_worker_unavailable':503,'plugin_job_storage_unavailable':503,
      'plugin_job_conflict':409,'plugin_job_limit_reached':409}.entries) {
      for (final status in [entry.value, 400]) {
        final api=LarenorServerApi(endpoint: ServerEndpoint('https://server.test'),client:MockClient((_) async =>
          http.Response(jsonEncode({'error':{'code':entry.key,'message':'untrusted input'}}),status,headers:{'content-type':'application/json'})));
        await expectLater(api.request('POST',jobs),throwsA(isA<LarenorServerException>().having((e)=>e.code,'code',status==entry.value?entry.key:'invalid_request')));
        api.close();
      }
    }
  });
}
