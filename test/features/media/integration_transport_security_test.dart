import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/media/arr/data/arr_client.dart';
import 'package:larenor/features/media/arr/data/arr_config.dart';
import 'package:larenor/features/media/arr/data/models/arr_lookup_result.dart';
import 'package:larenor/features/media/bazarr/data/bazarr_client.dart';
import 'package:larenor/features/media/bazarr/data/bazarr_config.dart';
import 'package:larenor/features/media/prowlarr/data/prowlarr_client.dart';
import 'package:larenor/features/media/prowlarr/data/prowlarr_config.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_client.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_config.dart';
import 'package:larenor/features/media/jellyseerr/data/jellyseerr_client.dart';
import 'package:larenor/features/media/jellyseerr/data/jellyseerr_config.dart';
import 'package:larenor/features/keenetic/data/keenetic_client.dart';
import 'package:larenor/features/keenetic/data/keenetic_config.dart';
import 'package:larenor/features/keenetic/data/keenetic_api_exception.dart';
import 'package:larenor/features/keenetic/data/keenetic_telemetry.dart';
import 'package:larenor/features/proxmox/data/proxmox_client.dart';
import 'package:larenor/features/proxmox/data/proxmox_config.dart';
import 'package:larenor/features/proxmox/data/proxmox_api_exception.dart';

void main() {
  const baseUrl = 'https://media.example.test';
  final probes = <String, Future<Object?> Function(http.Client)>{
    'Arr': (http) => ArrClient(
      config: const ArrConfig(baseUrl: baseUrl, apiKey: 'secret'),
      resourcePath: 'series',
      idFieldName: 'tvdbId',
      httpClient: http,
    ).checkConnection(),
    'Bazarr': (http) => BazarrClient(
      config: const BazarrConfig(baseUrl: baseUrl, apiKey: 'secret'),
      httpClient: http,
    ).checkConnection(),
    'Prowlarr': (http) => ProwlarrClient(
      config: const ProwlarrConfig(baseUrl: baseUrl, apiKey: 'secret'),
      httpClient: http,
    ).checkConnection(),
    'Jellyseerr': (http) => JellyseerrClient(
      config: const JellyseerrConfig(baseUrl: baseUrl, apiKey: 'secret'),
      httpClient: http,
    ).checkConnection(),
    'Jellyfin': (http) => JellyfinClient(
      config: const JellyfinConfig(
        baseUrl: baseUrl,
        userId: 'user',
        accessToken: 'secret',
        deviceId: 'device',
      ),
      httpClient: http,
    ).getLibraries(),
    'Jellyfin login': (http) => JellyfinClient.login(
      baseUrl: baseUrl,
      username: 'user',
      password: 'secret',
      deviceId: 'device',
      httpClient: http,
    ),
    'Keenetic': (http) => KeeneticClient(
      config: const KeeneticConfig(
        baseUrl: baseUrl,
        username: 'user',
        password: 'secret',
      ),
      httpClient: http,
    ).login(),
    'Proxmox': (http) => ProxmoxClient(
      config: const ProxmoxConfig(
        host: 'media.example.test',
        port: 8006,
        username: 'root',
        realm: 'pam',
        password: 'secret',
        allowSelfSigned: true,
      ),
      httpClient: http,
    ).login(),
  };

  for (final probe in probes.entries) {
    test(
      '${probe.key} blocks redirects before forwarding credentials',
      () async {
        var calls = 0;
        final transport = MockClient((request) async {
          calls++;
          expect(request.followRedirects, isFalse);
          return http.Response(
            '',
            307,
            headers: {'location': 'https://untrusted.test/?secret=credential'},
          );
        });
        addTearDown(transport.close);
        await expectLater(
          probe.value(transport),
          throwsA(switch (probe.key) {
            'Keenetic' => isA<KeeneticApiException>().having(
              (error) => error.failure,
              'failure',
              KeeneticReadFailure.transport,
            ),
            'Proxmox' => isA<ProxmoxApiException>().having(
              (error) => error.failure,
              'failure',
              ProxmoxFailure.transport,
            ),
            _ => isA<http.ClientException>(),
          }),
        );
        expect(calls, 1);
      },
    );
  }

  test(
    'Jellyseerr failure does not surface a credential-bearing error body',
    () async {
      final client = JellyseerrClient(
        config: const JellyseerrConfig(baseUrl: baseUrl, apiKey: 'private-key'),
        httpClient: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'error': 'Invalid API key: private-key',
              'html': '<html>proxy</html>',
            }),
            400,
          ),
        ),
      );
      addTearDown(client.dispose);
      await expectLater(
        client.requestMedia(mediaType: 'movie', mediaId: 1),
        throwsA(
          predicate(
            (Object error) =>
                !error.toString().contains('private-key') &&
                !error.toString().contains('<html>') &&
                error.toString().contains('400'),
          ),
        ),
      );
    },
  );
  test('Arr failure does not expose proxy response bodies', () async {
    final client = ArrClient(
      config: const ArrConfig(baseUrl: baseUrl, apiKey: 'private-key'),
      resourcePath: 'movie',
      idFieldName: 'tmdbId',
      httpClient: MockClient(
        (request) async =>
            http.Response('<html>Invalid key: private-key</html>', 400),
      ),
    );
    addTearDown(client.dispose);
    await expectLater(
      client.add(
        result: ArrLookupResult.fromJson({
          'tmdbId': 1,
          'title': 'Movie',
        }, idFieldName: 'tmdbId'),
        qualityProfileId: 1,
        rootFolderPath: '/movies',
      ),
      throwsA(
        predicate(
          (Object error) =>
              !error.toString().contains('private-key') &&
              !error.toString().contains('<html>') &&
              error.toString().contains('400'),
        ),
      ),
    );
  });

  test('Proxmox validation errors expose status without response bodies or secrets', () async {
    final client = ProxmoxClient(
      config: const ProxmoxConfig(
        host: 'proxmox.local',
        port: 8006,
        username: 'root',
        realm: 'pam',
        password: 'private/password',
        allowSelfSigned: true,
      ),
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/access/ticket')) {
          return http.Response(
            jsonEncode({
              'data': {
                'ticket': 'private-ticket',
                'CSRFPreventionToken': 'private-csrf',
              },
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'errors': {
              'validation': 'private/password private%2Fpassword private-ticket private-csrf',
            },
          }),
          400,
        );
      }),
    );
    addTearDown(client.dispose);
    await expectLater(
      client.getNodes(),
      throwsA(
        predicate(
          (Object error) =>
              error is ProxmoxApiException &&
              error.statusCode == 400 &&
              error.failure == ProxmoxFailure.invalidResponse &&
              !error.toString().contains('validation:') &&
              !error.toString().contains('private'),
        ),
      ),
    );
  });

  test(
    'Keenetic command rejection excludes password and session cookie values',
    () async {
      final client = KeeneticClient(
        config: const KeeneticConfig(
          baseUrl: baseUrl,
          username: 'user',
          password: 'private-password',
        ),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/auth')) {
            return http.Response(
              '',
              200,
              headers: {'set-cookie': 'session=private-session; Path=/'},
            );
          }
          return http.Response(
            jsonEncode({
              'status': 'error',
              'message': 'Rejected private-password private-session',
            }),
            200,
          );
        }),
      );
      addTearDown(client.dispose);
      await client.login();
      await expectLater(
        client.setInterfaceUp('WifiMaster0/AccessPoint0', true),
        throwsA(
          predicate(
            (Object error) =>
                error is KeeneticApiException &&
                error.failure == KeeneticReadFailure.rejected &&
                !error.toString().contains('private'),
          ),
        ),
      );
    },
  );
}
