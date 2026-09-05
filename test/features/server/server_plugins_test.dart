import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/plugins/data/server_plugins_controller.dart';
import 'package:larenor/features/server/plugins/domain/server_plugin_models.dart';

import 'server_plugins_test_support.dart';

void main() {
  final invalid = throwsA(
    isA<LarenorServerException>().having(
      (error) => error.code,
      'code',
      'invalid_response',
    ),
  );

  test(
    'the real pinned catalog and all fourteen Python plans match Client models',
    () {
      final fixture = pluginFixtureJson();
      final catalog = ServerPluginCatalog.fromJson(fixture['catalog']);
      expect(catalog.entries, hasLength(6));
      expect(catalog.workerAvailable, isFalse);
      for (final value in fixture['plans'] as List) {
        final plan = PluginInstallPlan.fromJson(value['plan']);
        final entry = catalog.entries.singleWhere(
          (entry) => entry.manifest.serviceId == value['serviceId'],
        );
        expect(
          plan.matches(
            entry,
            value['platform'],
            Map<String, Object?>.from(value['settings']),
          ),
          isTrue,
          reason: '${value['serviceId']} ${value['settings']}',
        );
        expect(plan.installable, isFalse);
      }
      Object? canonical(Object? value) => switch (value) {
        Map value => {
          for (final key in (value.keys.cast<String>().toList()..sort()))
            key: canonical(value[key]),
        },
        List value => value.map(canonical).toList(),
        _ => value,
      };
      final actual = jsonDecode(
        File('server/larenor_server/plugins/packagedcatalog.json')
            .readAsStringSync(),
      );
      expect(
        sha256.convert(utf8.encode(jsonEncode(canonical(actual)))).toString(),
        catalog.digest,
      );
    },
  );

  test(
    'catalog and settings are immutable and UI accepts only fixed scalar forms',
    () {
      final catalog = ServerPluginCatalog.fromJson(pluginCatalogJson());
      expect(() => catalog.entries.clear(), throwsUnsupportedError);
      final jellyfin = catalog.entries.first.manifest;
      expect(() => jellyfin.images.clear(), throwsUnsupportedError);
      expect(
        () => jellyfin.defaultSettings['dataRootId'] = '/mnt',
        throwsUnsupportedError,
      );
      expect(
        jellyfin.acceptsSettings({
          ...jellyfin.defaultSettings,
          'dataRootId': '/mnt/media',
        }),
        isFalse,
      );
      expect(
        jellyfin.acceptsSettings({...jellyfin.defaultSettings, 'webPort': 80}),
        isFalse,
      );
      expect(
        jellyfin.acceptsSettings({
          ...jellyfin.defaultSettings,
          'webPort': '8096',
        }),
        isFalse,
      );
      expect(
        jellyfin.acceptsSettings({
          ...jellyfin.defaultSettings,
          'password': 'never-enter-a-secret',
        }),
        isFalse,
      );
      expect(
        jellyfin.acceptsSettings({
          ...jellyfin.defaultSettings,
          'mediaRootId': null,
        }),
        isTrue,
      );
      final qbit = catalog.entries
          .singleWhere((entry) => entry.manifest.serviceId == 'qbittorrent')
          .manifest;
      expect(
        qbit.acceptsSettings({
          ...qbit.defaultSettings,
          'torrentPort': qbit.defaultSettings['webPort'],
        }),
        isFalse,
      );
      for (final spec in jellyfin.settings) {
        expect(
          spec.accepts(spec.parseInput(spec.defaultValue?.toString() ?? '')),
          isTrue,
        );
      }
    },
  );

  final badCatalogs = <String, void Function(Map<String, dynamic>)>{
    'unknown top-level secret': (v) => v['token'] = 'synthetic-provider-secret',
    'missing worker': (v) => v.remove('worker'),
    'enabled worker': (v) => v['worker']['available'] = true,
    'guessed worker platform': (v) => v['worker']['platform'] = 'linux/arm64',
    'unknown worker reason': (v) => v['worker']['reason'] = 'ready',
    'oversized catalog': (v) => v['entries'].add(v['entries'].first),
    'empty catalog': (v) => v['entries'] = [],
    'duplicate service': (v) => v['entries'][1] = v['entries'][0],
    'wrong catalog binding': (v) => v['entries'][0]['catalogDigest'] = 'b' * 64,
    'bad digest': (v) => v['entries'][0]['manifestDigest'] = 'sha256:no',
  };
  for (final example in badCatalogs.entries) {
    test('catalog rejects ${example.key}', () {
      final json = pluginCatalogJson();
      example.value(json);
      expect(() => ServerPluginCatalog.fromJson(json), invalid);
    });
  }

  final badManifests = <String, void Function(Map<String, dynamic>)>{
    'unexpected credentials': (v) =>
        v['credentials'] = {'token': 'synthetic-provider-secret'},
    'missing field': (v) => v.remove('licenseUrl'),
    'enabled installation': (v) => v['installable'] = true,
    'unknown service': (v) => v['serviceId'] = 'arbitrary_image',
    'wrong integration role': (v) => v['integrationRole'] = 'internal_engine',
    'unknown version schema': (v) => v['manifestVersion'] = 2,
    'invalid URL': (v) => v['licenseUrl'] = 'https://user:secret@example.test',
    'control text': (v) => v['displayName'] = 'Hello\nworld',
    'unknown platform': (v) => v['images'][0]['platform'] = 'linux/arm/v7',
    'duplicate platform': (v) => v['images'][1] = v['images'][0],
    'bad image digest': (v) => v['images'][0]['digest'] = 'latest',
    'privileged security': (v) => v['security']['privileged'] = true,
    'new privileges': (v) => v['security']['noNewPrivileges'] = false,
    'root outside music': (v) => v['security']['user'] = '0:0',
    'new capability': (v) => v['security']['capAdd'] = ['SYS_ADMIN'],
    'host network outside music': (v) => v['network']['mode'] = 'host',
    'unknown listener purpose': (v) =>
        v['network']['listeners'][0]['purpose'] = 'admin',
    'zero listener port': (v) => v['network']['listeners'][0]['port'] = 0,
    'arbitrary host binding': (v) => v['ports'][0]['hostIp'] = '127.0.0.1',
    'privileged host port': (v) => v['ports'][0]['hostPort'] = 80,
    'absolute host path': (v) => v['mounts'][0]['rootId'] = '/etc',
    'relative traversal': (v) => v['mounts'][0]['relativePath'] = '../config',
    'readonly managed appdata': (v) => v['mounts'][0]['readOnly'] = true,
    'duplicate mount target': (v) =>
        v['mounts'][1]['target'] = v['mounts'][0]['target'],
    'string memory': (v) => v['resources']['memoryMiB'] = '1024',
    'unbounded CPU': (v) => v['resources']['cpuMillis'] = 999999,
    'secret environment': (v) => v['environment'] = [
      {'name': 'TOKEN', 'value': 'synthetic-secret'},
    ],
    'unknown setting': (v) => v['settings'][0]['name'] = 'apiKey',
    'setting kind drift': (v) => v['settings'][0]['kind'] = 'root_id',
    'arbitrary port range': (v) => v['settings'][2]['minimum'] = 1,
    'fractional port': (v) => v['settings'][2]['default'] = 8080.5,
    'duplicate settings': (v) => v['settings'][1] = v['settings'][0],
    'bad optional root': (v) => v['settings'][3]['default'] = '../media',
    'secret health headers': (v) =>
        v['health']['headers'] = {'Authorization': 'synthetic-secret'},
  };
  for (final example in badManifests.entries) {
    test('manifest rejects ${example.key} without reflecting values', () {
      final json = pluginCatalogJson();
      example.value(json['entries'][0]['manifest']);
      expect(() => ServerPluginCatalog.fromJson(json), invalid);
      try {
        ServerPluginCatalog.fromJson(json);
      } catch (error) {
        expect(error.toString(), isNot(contains('synthetic')));
      }
    });
  }

  test('preview expiry is bounded to exactly ten minutes and cannot enable execution', () {
    final valid = pluginPreviewJson()['preview'];
    final preview = ServerPluginPreview.fromJson(valid);
    expect(preview.expired(preview.expiresAt), isTrue);
    expect(preview.expired(preview.createdAt), isFalse);
    for (final changed in [
      {...valid, 'id': 'x' * 32},
      {...valid, 'revision': 2},
      {...valid, 'createdAt': '2026-09-05T09:00:00+03:00'},
      {
        ...valid,
        'expiresAt': preview.expiresAt
            .add(const Duration(seconds: 1))
            .toIso8601String(),
      },
      {...valid, 'extra': 'synthetic-secret'},
      {
        ...valid,
        'plan': {...valid['plan'], 'installable': true},
      },
      {
        ...valid,
        'plan': {...valid['plan'], 'blockers': []},
      },
    ]) {
      expect(() => ServerPluginPreview.fromJson(changed), invalid);
    }
  });

  group('guarded real API controller', () {
    late PluginsFixture fixture;
    late ServerPluginsController controller;
    var current = true;
    setUp(() async {
      fixture = PluginsFixture();
      await fixture.account.initialize();
      controller = ServerPluginsController(fixture.account);
      current = true;
    });
    tearDown(() {
      controller.dispose();
      fixture.account.dispose();
    });
    Future<void> load() => controller.load(current: () => current);
    Future<void> review() => controller.review(
      controller.catalog!.entries.first,
      platform: 'linux/amd64',
      settings: controller.catalog!.entries.first.manifest.defaultSettings,
      current: () => current,
    );

    test('catalog read is single-flight and never performs an install or preview automatically', () async {
      final response = Completer<http.Response>();
      fixture.respond = (_) => response.future;
      final first = load();
      await Future<void>.delayed(Duration.zero);
      final second = load();
      expect(controller.busy, isTrue);
      expect(fixture.adminCalls.length, 1);
      response.complete(fixture.json(pluginCatalogJson()));
      await Future.wait([first, second]);
      expect(controller.catalog!.entries, hasLength(6));
      expect(fixture.mutations, isEmpty);
    });

    test('only explicit review creates a bound metadata preview and no credentials', () async {
      await load();
      await review();
      expect(controller.preview!.plan.installable, isFalse);
      expect(fixture.mutations, hasLength(1));
      final request = fixture.mutations.single;
      expect(request.url.path, '/prefix/api/v1/admin/plugins/previews');
      expect((jsonDecode(request.body) as Map).keys.toSet(), {
        'serviceId',
        'distributionId',
        'manifestDigest',
        'platform',
        'settings',
      });
      expect(request.body, isNot(contains('token')));
      controller.clearPreview();
      expect(controller.preview, isNull);
      expect(
        fixture.calls.any(
          (call) =>
              call.url.path.contains('/jobs') ||
              call.url.path.contains('/install'),
        ),
        isFalse,
      );
    });

    for (final mode in ['hidden', 'logout', 'invalidate', 'dispose']) {
      test('$mode discards a late catalog response', () async {
        final response = Completer<http.Response>();
        fixture.respond = (_) => response.future;
        final pending = load();
        await Future<void>.delayed(Duration.zero);
        if (mode == 'hidden') current = false;
        if (mode == 'invalidate') controller.invalidate();
        if (mode == 'logout') await fixture.account.signOut();
        if (mode == 'dispose') {
          controller.dispose();
          controller = ServerPluginsController(fixture.account);
        }
        response.complete(fixture.json(pluginCatalogJson()));
        await pending;
        expect(controller.catalog, isNull);
        expect(controller.preview, isNull);
      });
    }

    test(
      'a retained callback cannot review an entry from an old catalog',
      () async {
        await load();
        final old = controller.catalog!.entries.first;
        await load();
        await controller.review(
          old,
          platform: 'linux/amd64',
          settings: old.manifest.defaultSettings,
          current: () => true,
        );
        expect(fixture.mutations, isEmpty);
      },
    );

    test(
      'preview is single-flight and invalidation discards a late response',
      () async {
        await load();
        final response = Completer<http.Response>();
        fixture.respond = (_) => response.future;
        final pending = review();
        await Future<void>.delayed(Duration.zero);
        await review();
        expect(fixture.mutations, hasLength(1));
        controller.invalidate();
        response.complete(fixture.json(pluginPreviewJson(), 201));
        await pending;
        expect(controller.preview, isNull);
        expect(controller.catalog, isNull);
      },
    );

    test(
      'uncertain preview never retries and needs an explicit catalog refresh',
      () async {
        await load();
        fixture.respond = (_) async =>
            throw TimeoutException('synthetic-secret');
        await review();
        expect(controller.needsRefresh, isTrue);
        expect(controller.preview, isNull);
        final count = fixture.mutations.length;
        await review();
        expect(fixture.mutations.length, count);
        expect(controller.failure, isNot(contains('synthetic')));
        fixture.respond = (request) async => fixture.pluginResponse(request);
        await load();
        expect(controller.needsRefresh, isFalse);
        await review();
        expect(controller.preview, isNotNull);
      },
    );

    final changedPlans = <String, void Function(Map<String, dynamic>)>{
      'service': (v) => v['serviceId'] = 'seerr',
      'catalog': (v) => v['catalogDigest'] = 'b' * 64,
      'manifest': (v) => v['manifestDigest'] = 'b' * 64,
      'distribution': (v) => v['distributionId'] = 'linuxserver',
      'platform': (v) => v['image']['platform'] = 'linux/arm64',
      'digest': (v) {
        v['image']['digest'] = 'sha256:${'b' * 64}';
        v['image']['reference'] =
            '${v['image']['repository']}:${v['image']['tag']}@${v['image']['digest']}';
      },
      'settings': (v) => v['settings'].firstWhere(
        (item) => item['name'] == 'webPort',
      )['value'] = 9000,
      'mount effects': (v) => v['mounts'][0]['rootId'] = 'other',
      'port effects': (v) => v['ports'][0]['hostPort'] = 9000,
      'resource effects': (v) => v['resources']['memoryMiB'] = 9000,
      'security effects': (v) => v['security']['init'] = true,
      'health effects': (v) => v['health']['path'] = '/other',
      'warning effects': (v) => v['warnings'] = [],
      'enabled installation': (v) => v['installable'] = true,
      'unexpected envelope': (v) => v['credentials'] = 'synthetic-secret',
    };
    for (final change in changedPlans.entries) {
      test('preview rejects changed ${change.key}', () async {
        await load();
        final response = pluginPreviewJson();
        change.value(response['preview']['plan']);
        fixture.respond = (_) async => fixture.json(response, 201);
        await review();
        expect(controller.failure, 'invalid_response');
        expect(controller.preview, isNull);
        expect(controller.catalog, isNull);
        expect(controller.needsRefresh, isTrue);
      });
    }

    test('invalid port/root/platform never reaches the Server', () async {
      await load();
      final entry = controller.catalog!.entries.first;
      await controller.review(
        entry,
        platform: 'linux/arm/v7',
        settings: entry.manifest.defaultSettings,
        current: () => true,
      );
      expect(controller.failure, 'invalid_request');
      expect(fixture.mutations, isEmpty);
      await load();
      final refreshed = controller.catalog!.entries.first;
      await controller.review(
        refreshed,
        platform: 'linux/amd64',
        settings: {...refreshed.manifest.defaultSettings, 'dataRootId': '/etc'},
        current: () => true,
      );
      expect(controller.failure, 'invalid_request');
      expect(fixture.mutations, isEmpty);
    });
  });
}
