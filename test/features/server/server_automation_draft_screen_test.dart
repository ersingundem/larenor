import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/server/automation_drafts/presentation/server_automation_draft_screen.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import 'server_admin_test_support.dart';

const _speechChannel = MethodChannel('com.ersingundem.larenor/local_speech');
final _coreId = 'a' * 32;
final _homeId = 'b' * 32;
final _firstTargetId = '1' * 32;
final _secondTargetId = '2' * 32;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AdminFixture fixture;
  late _AutomationBackend backend;

  setUp(() async {
    backend = _AutomationBackend();
    fixture = AdminFixture()..respond = backend.respond;
    await fixture.account.initialize();
    expect(fixture.account.initialized, isTrue);
    expect(fixture.account.context?.coreId, _coreId);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_speechChannel, null);
    fixture.account.dispose();
  });

  testWidgets(
    'explicit target selection creates its preview and editing retires it',
    (tester) async {
      await _mount(tester, fixture);

      await _tapKey(tester, 'automation-draft-targets');
      expect(find.text('Kitchen light'), findsOneWidget);
      expect(find.text('Desk light'), findsOneWidget);
      expect(backend.draftBodies, isEmpty);

      await _tapKey(tester, 'automation-draft-target-$_secondTargetId');
      await tester.enterText(
        find.byKey(const ValueKey('automation-draft-transcript')),
        'turn on',
      );
      await tester.pump();
      await _tapText(tester, 'Preview draft');

      expect(backend.draftBodies, hasLength(1));
      expect(backend.draftBodies.single['resourceId'], _secondTargetId);
      expect(backend.draftBodies.single['transcript'], 'turn on');
      expect(
        find.text('ha-switch-actions-v1 · ${_secondTargetId.substring(0, 8)}'),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const ValueKey('automation-draft-transcript')),
        'turn off',
      );
      await tester.pump();

      expect(
        find.text('ha-switch-actions-v1 · ${_secondTargetId.substring(0, 8)}'),
        findsNothing,
      );
      expect(backend.draftBodies, hasLength(1));
    },
  );

  testWidgets('permission gesture cannot start recognition or create a draft', (
    tester,
  ) async {
    var microphoneGranted = false;
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_speechChannel, (call) async {
          calls.add(call.method);
          return switch (call.method) {
            'probe' => <String, Object>{
              'schemaVersion': 1,
              'onDeviceAvailable': true,
              'microphoneGranted': microphoneGranted,
            },
            'requestPermission' => microphoneGranted = true,
            'recognize' => <String, Object>{
              'schemaVersion': 1,
              'onDevice': true,
              'text': 'turn on',
            },
            'cancel' => null,
            _ => throw PlatformException(code: 'unexpected_method'),
          };
        });
    await _mount(tester, fixture);

    await _tapKey(tester, 'automation-draft-speech');

    expect(calls, ['probe', 'requestPermission']);
    expect(backend.draftBodies, isEmpty);
    expect(
      tester
          .widget<CupertinoTextField>(
            find.byKey(const ValueKey('automation-draft-transcript')),
          )
          .controller!
          .text,
      isEmpty,
    );

    await _tapKey(tester, 'automation-draft-speech');

    expect(calls, ['probe', 'requestPermission', 'probe', 'recognize']);
    expect(backend.draftBodies, isEmpty);
    expect(
      tester
          .widget<CupertinoTextField>(
            find.byKey(const ValueKey('automation-draft-transcript')),
          )
          .controller!
          .text,
      'turn on',
    );
  });

  testWidgets('a failed target read can be retried by a fresh user gesture', (
    tester,
  ) async {
    backend.failResources = true;
    await _mount(tester, fixture);
    await _tapKey(tester, 'automation-draft-targets');
    expect(
      find.byKey(const ValueKey('automation-draft-retry')),
      findsOneWidget,
    );
    expect(find.text('Kitchen light'), findsNothing);
    expect(backend.draftBodies, isEmpty);
    backend.failResources = false;
    await _tapKey(tester, 'automation-draft-retry');
    expect(find.text('Kitchen light'), findsOneWidget);
    expect(find.text('Desk light'), findsOneWidget);
    expect(find.byKey(const ValueKey('automation-draft-retry')), findsNothing);
    expect(backend.draftBodies, isEmpty);
  });

  testWidgets('an empty verified target list explains the missing target', (
    tester,
  ) async {
    backend.emptyResources = true;
    await _mount(tester, fixture);
    await _tapKey(tester, 'automation-draft-targets');
    final l10n = AppLocalizations.of(
      tester.element(find.byType(ServerAutomationDraftScreen)),
    );
    expect(find.text(l10n.serverAutomationDraftTargetMissing), findsOneWidget);
    expect(backend.draftBodies, isEmpty);
  });
}

Future<void> _mount(WidgetTester tester, AdminFixture fixture) async {
  tester.view.physicalSize = const Size(900, 1500);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        serverAccountControllerProvider.overrideWithValue(fixture.account),
      ],
      child: CupertinoApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const ServerAutomationDraftScreen(gateCurrent: _alwaysCurrent),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

bool _alwaysCurrent() => true;

Future<void> _tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.scrollUntilVisible(
    finder,
    250,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _tapText(WidgetTester tester, String text) async {
  final finder = find.text(text);
  await tester.scrollUntilVisible(
    finder,
    250,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

final class _AutomationBackend {
  final draftBodies = <Map<String, dynamic>>[];
  bool failResources = false, emptyResources = false;

  http.Response json(Object value, [int status = 200]) => http.Response(
    jsonEncode(value),
    status,
    headers: {'content-type': 'application/json'},
  );

  Map<String, Object?> resource(String id, String label) => {
    'ref': {
      'schemaVersion': 1,
      'coreId': _coreId,
      'homeId': _homeId,
      'kind': 'resource',
      'id': id,
    },
    'label': label,
    'order': id == _firstTargetId ? 0 : 1,
    'revision': 1,
    'aclRevision': 1,
    'permissions': {'read': true, 'write': true},
  };

  Map<String, Object?> snapshot(String id) => {
    'schemaVersion': 1,
    'ref': {
      'schemaVersion': 1,
      'coreId': _coreId,
      'homeId': _homeId,
      'kind': 'resource',
      'id': id,
    },
    'bindingId': '4' * 32,
    'bindingRevision': 1,
    'resourceRevision': 1,
    'aclRevision': 1,
    'serviceRevision': 1,
    'observedAt': '2026-09-30T08:00:00Z',
    'remainingTtlMs': 5000,
    'projection': {'kind': 'switch', 'state': 'off', 'commandAvailable': true},
  };

  Future<http.Response> respond(http.Request request) async {
    final path = request.url.path;
    if (path.endsWith('/context')) {
      return json({'schemaVersion': 1, 'coreId': _coreId, 'homeId': _homeId});
    }
    if (path.endsWith('/home-resources/$_coreId/$_homeId')) {
      if (failResources) {
        return json({
          'error': {'code': 'server_error'},
        }, 503);
      }
      return json({
        'scope': {'schemaVersion': 1, 'coreId': _coreId, 'homeId': _homeId},
        'userRevision': 1,
        'entries': emptyResources
            ? []
            : [
                resource(_firstTargetId, 'Kitchen light'),
                resource(_secondTargetId, 'Desk light'),
              ],
        'snapshot': 'c' * 64,
        'nextAfter': null,
      });
    }
    for (final id in [_firstTargetId, _secondTargetId]) {
      if (path.endsWith(
        '/home-assistant/$_coreId/$_homeId/resources/$id/snapshot',
      )) {
        return json({'snapshot': snapshot(id)});
      }
    }
    if (path.endsWith('/automation-drafts/$_coreId/$_homeId/actions')) {
      return json({
        'schemaVersion': 1,
        'catalogVersion': 'ha-switch-actions-v1',
        'actions': ['turn_on', 'turn_off'],
        'deviceCommandAvailable': false,
      });
    }
    if (request.method == 'POST' &&
        path.endsWith('/automation-drafts/$_coreId/$_homeId')) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      draftBodies.add(body);
      final resourceId = body['resourceId'] as String;
      return json({
        'draft': {
          'schemaVersion': 1,
          'id': '7' * 32,
          'revision': 1,
          'state': 'draft',
          'catalogVersion': 'ha-switch-actions-v1',
          'target': {'resourceId': resourceId},
          'action': 'turn_on',
          'steps': ['validate_current_target', 'create_inert_rule'],
          'sideEffects': ['creates_automation_rule', 'does_not_execute_device'],
          'expiresAt': 1790762400.0,
          'expired': false,
          'requiresExplicitConfirmation': true,
          'deviceCommandAvailable': false,
          'rule': null,
        },
      }, 201);
    }
    return json({
      'error': {'code': 'not_found'},
    }, 404);
  }
}
