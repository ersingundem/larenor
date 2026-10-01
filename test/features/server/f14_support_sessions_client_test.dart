import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/server/presentation/server_connection_screen.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/features/server/support_sessions/data/server_support_sessions_controller.dart';
import 'package:larenor/features/server/support_sessions/domain/server_support_session_models.dart';
import 'package:larenor/features/server/support_sessions/presentation/server_support_sessions_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import 'server_admin_test_support.dart';

const _sessionId = '11111111111111111111111111111111';
const _supporterId = 'fixture.supporter';
const _token = 'TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT';

Map<String, Object?> _sessionJson({
  String state = 'active',
  int revision = 1,
}) => {
  'schemaVersion': 1,
  'id': _sessionId,
  'revision': revision,
  'supporterId': _supporterId,
  'supporterName': 'Bounded support fixture',
  'permissions': const ['core:health.read'],
  'state': state,
  'expiresAt': 1788599400.0,
  'remainingSeconds': state == 'active' ? 900 : 0,
  'createdAt': 1788598800.0,
  'updatedAt': 1788598800.0,
  'logPolicy': {
    'freeformLogsStored': false,
    'redactedFields': const [
      'authorization',
      'cookies',
      'credentials',
      'requestBody',
      'responseBody',
      'freeformLogs',
    ],
  },
};

Map<String, Object?> _listJson([
  List<Map<String, Object?>> sessions = const [],
]) => {
  'schemaVersion': 1,
  'sessions': sessions,
  'maximumSessions': 64,
  'maximumLifetimeSeconds': 1200,
};

Future<void> _initialize(AdminFixture fixture) async {
  await fixture.account.initialize();
  expect(fixture.account.session?.user.canAdminister, isTrue);
  expect(fixture.account.session?.context, isNotNull);
}

Future<void> _mountSupport(
  WidgetTester tester,
  AdminFixture fixture, {
  Widget? home,
}) async {
  tester.view.physicalSize = const Size(900, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        serverAccountControllerProvider.overrideWithValue(fixture.account),
      ],
      child: CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: home ?? const ServerSupportSessionsScreen(gateCurrent: _always),
      ),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    fixture.account.dispose();
  });
}

bool _always() => true;

Future<void> _openCreateDialog(WidgetTester tester) async {
  await tester.tap(find.byIcon(CupertinoIcons.add));
  await tester.pumpAndSettle();
  final fields = find.byType(CupertinoTextField);
  expect(fields, findsNWidgets(2));
  await tester.enterText(fields.at(0), 'Bounded support fixture');
  await tester.enterText(fields.at(1), _supporterId);
  await tester.tap(
    find.widgetWithText(CupertinoDialogAction, 'Create support session'),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('strict models keep one-view token outside the public session', () {
    final issued = ServerSupportIssuedSession.fromJson({
      'session': _sessionJson(),
      'accessToken': _token,
    });
    expect(issued.accessToken, _token);
    expect(issued.session.supporterId, _supporterId);
    expect(issued.session.logPolicy.redactedFields, contains('authorization'));
    expect(issued.session.toString(), isNot(contains(_token)));
    expect(
      () => ServerSupportIssuedSession.fromJson({
        'session': _sessionJson(),
        'accessToken': 'short',
      }),
      throwsA(isA<Exception>()),
    );
  });

  test(
    'late create response cannot commit into a retired controller',
    () async {
      final fixture = AdminFixture();
      await _initialize(fixture);
      final response = Completer<http.Response>();
      fixture.respond = (request) {
        expect(request.method, 'POST');
        return response.future;
      };
      final controller = ServerSupportSessionsController(fixture.account);
      var current = true;
      final pending = controller.create(
        supporterId: _supporterId,
        supporterName: 'Bounded support fixture',
        permissions: const ['core:health.read'],
        current: () => current,
      );
      await Future<void>.delayed(Duration.zero);
      current = false;
      controller.invalidate();
      response.complete(
        fixture.json({'session': _sessionJson(), 'accessToken': _token}, 201),
      );
      await pending;
      expect(controller.sessions, isEmpty);
      expect(controller.takeIssuedToken(), isNull);
      expect(controller.announcement, isNull);
      controller.dispose();
      fixture.account.dispose();
    },
  );

  test('uncertain create reconciles by GET without replaying POST', () async {
    final fixture = AdminFixture();
    await _initialize(fixture);
    var persisted = false;
    fixture.respond = (request) async {
      if (request.method == 'POST') {
        persisted = true;
        return fixture.json({
          'error': {'code': 'server_error'},
        }, 500);
      }
      expect(request.method, 'GET');
      return fixture.json(_listJson(persisted ? [_sessionJson()] : const []));
    };
    final controller = ServerSupportSessionsController(fixture.account);
    await controller.create(
      supporterId: _supporterId,
      supporterName: 'Bounded support fixture',
      permissions: const ['core:health.read'],
      current: _always,
    );
    expect(controller.needsRefresh, isTrue);
    expect(controller.takeIssuedToken(), isNull);
    await controller.refresh(_always);
    expect(controller.needsRefresh, isFalse);
    expect(controller.sessions.single.id, _sessionId);
    final supportCalls = fixture.calls.where(
      (request) => request.url.path.contains('/support-sessions/'),
    );
    expect(
      supportCalls.where((request) => request.method == 'POST'),
      hasLength(1),
    );
    expect(
      supportCalls.where((request) => request.method == 'GET'),
      hasLength(1),
    );
    controller.dispose();
    fixture.account.dispose();
  });

  testWidgets('admin entry opens the current-home support route', (
    tester,
  ) async {
    final fixture = AdminFixture();
    await _initialize(fixture);
    fixture.respond = (request) async {
      if (request.url.path.contains('/support-sessions/')) {
        return fixture.json(_listJson());
      }
      return fixture.defaultResponse(request);
    };
    await _mountSupport(tester, fixture, home: const ServerConnectionScreen());
    final entry = find.byKey(const ValueKey('server-support-sessions'));
    expect(entry, findsOneWidget);
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.byType(ServerSupportSessionsScreen), findsOneWidget);
    expect(
      find.text('No support session exists for this home.'),
      findsOneWidget,
    );
  });

  testWidgets('uncertain create exposes safe read-only reconciliation', (
    tester,
  ) async {
    final fixture = AdminFixture();
    await _initialize(fixture);
    var createAttempted = false;
    fixture.respond = (request) async {
      if (request.method == 'POST') {
        createAttempted = true;
        return fixture.json({
          'error': {'code': 'server_error'},
        }, 500);
      }
      return fixture.json(
        _listJson(createAttempted ? [_sessionJson()] : const []),
      );
    };
    await _mountSupport(tester, fixture);
    await _openCreateDialog(tester);
    expect(find.text('Refresh'), findsOneWidget);
    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();
    expect(find.text('Bounded support fixture'), findsOneWidget);
    final supportCalls = fixture.calls.where(
      (request) => request.url.path.contains('/support-sessions/'),
    );
    expect(
      supportCalls.where((request) => request.method == 'POST'),
      hasLength(1),
    );
    expect(
      supportCalls.where((request) => request.method == 'GET'),
      hasLength(2),
    );
  });

  testWidgets(
    'token dialog copies once only while exact authority is current',
    (tester) async {
      final fixture = AdminFixture();
      await _initialize(fixture);
      fixture.respond = (request) async {
        if (request.method == 'POST') {
          return fixture.json({
            'session': _sessionJson(),
            'accessToken': _token,
          }, 201);
        }
        return fixture.json(_listJson());
      };
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard =
                (call.arguments as Map<Object?, Object?>)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await _mountSupport(tester, fixture);
      await _openCreateDialog(tester);
      expect(find.text(_token), findsOneWidget);
      await tester.tap(find.text('Copy and close'));
      await tester.pumpAndSettle();
      expect(clipboard, _token);
      expect(find.text(_token), findsNothing);
    },
  );

  testWidgets('logout dismisses token dialog and captured copy stays inert', (
    tester,
  ) async {
    final fixture = AdminFixture();
    await _initialize(fixture);
    fixture.respond = (request) async {
      if (request.method == 'POST') {
        return fixture.json({
          'session': _sessionJson(),
          'accessToken': _token,
        }, 201);
      }
      return fixture.json(_listJson());
    };
    final clipboardWrites = <String?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardWrites.add(
            (call.arguments as Map<Object?, Object?>)['text'] as String?,
          );
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _mountSupport(tester, fixture);
    await _openCreateDialog(tester);
    final captured = tester
        .widget<CupertinoDialogAction>(
          find.widgetWithText(CupertinoDialogAction, 'Copy and close'),
        )
        .onPressed;
    await fixture.account.signOut();
    await tester.pumpAndSettle();
    expect(find.text(_token), findsNothing);
    captured?.call();
    await tester.pump();
    expect(clipboardWrites, isEmpty);
  });

  testWidgets('clipboard failure keeps the token dialog recoverable', (
    tester,
  ) async {
    final fixture = AdminFixture();
    await _initialize(fixture);
    fixture.respond = (request) async {
      if (request.method == 'POST') {
        return fixture.json({
          'session': _sessionJson(),
          'accessToken': _token,
        }, 201);
      }
      return fixture.json(_listJson());
    };
    var clipboardAttempts = 0;
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardAttempts++;
          if (clipboardAttempts == 1) {
            throw PlatformException(code: 'clipboard_unavailable');
          }
          clipboard =
              (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _mountSupport(tester, fixture);
    await _openCreateDialog(tester);
    await tester.tap(find.text('Copy and close'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text(_token), findsOneWidget);
    expect(find.text('Error'), findsOneWidget);
    expect(
      tester
          .widget<CupertinoDialogAction>(
            find.widgetWithText(CupertinoDialogAction, 'Copy and close'),
          )
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.text('Copy and close'));
    await tester.pumpAndSettle();
    expect(clipboardAttempts, 2);
    expect(clipboard, _token);
    expect(find.text(_token), findsNothing);
  });

  testWidgets('foreign route cannot reuse token callback or be popped', (
    tester,
  ) async {
    final fixture = AdminFixture();
    await _initialize(fixture);
    fixture.respond = (request) async {
      if (request.method == 'POST') {
        return fixture.json({
          'session': _sessionJson(),
          'accessToken': _token,
        }, 201);
      }
      return fixture.json(_listJson());
    };
    final clipboardWrites = <String?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardWrites.add(
            (call.arguments as Map<Object?, Object?>)['text'] as String?,
          );
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _mountSupport(tester, fixture);
    await _openCreateDialog(tester);
    final captured = tester
        .widget<CupertinoDialogAction>(
          find.widgetWithText(CupertinoDialogAction, 'Copy and close'),
        )
        .onPressed;
    final routeContext = tester.element(
      find.byType(ServerSupportSessionsScreen),
    );
    unawaited(
      Navigator.of(routeContext).push<void>(
        CupertinoPageRoute<void>(
          builder: (_) => const CupertinoPageScaffold(
            child: Center(child: Text('Foreign route')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Foreign route'), findsOneWidget);
    expect(find.text(_token), findsNothing);
    captured?.call();
    await tester.pump();
    expect(clipboardWrites, isEmpty);
    expect(find.text('Foreign route'), findsOneWidget);
  });

  testWidgets('late clipboard completion clears only the exact owned token', (
    tester,
  ) async {
    final fixture = AdminFixture();
    await _initialize(fixture);
    fixture.respond = (request) async {
      if (request.method == 'POST') {
        return fixture.json({
          'session': _sessionJson(),
          'accessToken': _token,
        }, 201);
      }
      return fixture.json(_listJson());
    };
    final firstWrite = Completer<void>();
    final clipboardWrites = <String?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          final text =
              (call.arguments as Map<Object?, Object?>)['text'] as String?;
          clipboardWrites.add(text);
          if (text == _token) await firstWrite.future;
        } else if (call.method == 'Clipboard.getData') {
          return <String, Object?>{'text': _token};
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _mountSupport(tester, fixture);
    await _openCreateDialog(tester);
    await tester.tap(find.text('Copy and close'));
    await tester.pump();
    expect(clipboardWrites, [_token]);
    await fixture.account.signOut();
    await tester.pump();
    firstWrite.complete();
    await tester.pumpAndSettle();
    expect(clipboardWrites, [_token, '']);
  });

  testWidgets('late clipboard completion never wipes a foreign replacement', (
    tester,
  ) async {
    final fixture = AdminFixture();
    await _initialize(fixture);
    fixture.respond = (request) async {
      if (request.method == 'POST') {
        return fixture.json({
          'session': _sessionJson(),
          'accessToken': _token,
        }, 201);
      }
      return fixture.json(_listJson());
    };
    final firstWrite = Completer<void>();
    final clipboardWrites = <String?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          final text =
              (call.arguments as Map<Object?, Object?>)['text'] as String?;
          clipboardWrites.add(text);
          if (text == _token) await firstWrite.future;
        } else if (call.method == 'Clipboard.getData') {
          return <String, Object?>{'text': 'foreign replacement'};
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _mountSupport(tester, fixture);
    await _openCreateDialog(tester);
    await tester.tap(find.text('Copy and close'));
    await tester.pump();
    expect(clipboardWrites, [_token]);
    await fixture.account.signOut();
    await tester.pump();
    firstWrite.complete();
    await tester.pumpAndSettle();
    expect(clipboardWrites, [_token]);
  });
}
