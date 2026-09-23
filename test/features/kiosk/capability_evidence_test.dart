import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/kiosk/capability_evidence/data/capability_evidence_api.dart';
import 'package:larenor/features/kiosk/capability_evidence/domain/capability_evidence_models.dart';
import 'package:larenor/features/kiosk/capability_evidence/presentation/capability_evidence_screen.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

Map<String, Object?> recordJson(Object? outcome, {String? id}) => {
  'schemaVersion': 1,
  'id': id ?? '0123456789abcdef0123456789abcdef',
  'revision': 2,
  'capabilityId': 'kiosk.window.lifecycle',
  'target': {
    'oem': 'Huawei',
    'model': 'MatePad 11.5 S 2026',
    'androidApi': 35,
    'webViewPackage': 'com.android.webview',
    'webViewVersion': '140.0.7339.51',
    'dexProfile': 'external_display',
    'permissions': ['android.permission.POST_NOTIFICATIONS'],
  },
  'outcome': outcome,
  'artifactName': 'k14-huawei-manual-gate.json',
  'artifactSha256': 'a' * 64,
  'sourceCommit': 'b' * 40,
  'testCase': 'manual.k14.huawei.window.lifecycle',
  'updatedAt': 1788609600.0,
};

ServerContext serverContext() => ServerContext.fromJson({
  'schemaVersion': 1,
  'coreId': 'a' * 32,
  'homeId': 'b' * 32,
});

http.Response jsonResponse(Object? body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  test(
    'strict model accepts only four outcomes and exact safe evidence links',
    () {
      for (final value in const [
        'tested',
        'failed',
        'untested',
        'manual_required',
      ]) {
        expect(
          CapabilityEvidenceRecord.fromJson(recordJson(value)).outcome.wireName,
          value,
        );
      }
      for (final value in ['passed', '', null, 1]) {
        expect(
          () => CapabilityEvidenceRecord.fromJson(recordJson(value)),
          throwsFormatException,
        );
      }
      for (final changes in [
        {'revision': jsonDecode('9223372036854775808')},
        {'artifactName': '/tmp/private'},
        {'artifactName': 'https:evil.invalid'},
        {'sourceCommit': 'B' * 40},
        {'testCase': '../../secret'},
        {'secret': 'must-not-enter-contract'},
      ]) {
        expect(
          () => CapabilityEvidenceRecord.fromJson({
            ...recordJson('untested'),
            ...changes,
          }),
          throwsFormatException,
        );
      }
    },
  );

  test('Core adapter rejects duplicate record ids within one page', () async {
    final context = serverContext();
    final duplicateId = '0' * 32;
    final transport = LarenorServerApi(
      endpoint: ServerEndpoint('https://core.invalid'),
      client: MockClient(
        (_) async => jsonResponse({
          'schemaVersion': 1,
          'scope': context.toJson(),
          'records': [
            recordJson('tested', id: duplicateId),
            recordJson('failed', id: duplicateId),
          ],
          'nextAfter': null,
        }),
      ),
    );
    addTearDown(transport.close);

    await expectLater(
      CapabilityEvidenceApi(transport, 'x' * 43, context).list(),
      throwsA(
        isA<LarenorServerException>().having(
          (error) => error.code,
          'code',
          'invalid_response',
        ),
      ),
    );
  });

  test('Core adapter paginates exact scope and rejects public-shape drift', () async {
    final context = serverContext();
    var page = 0;
    final transport = LarenorServerApi(
      endpoint: ServerEndpoint('https://core.invalid'),
      client: MockClient((request) async {
        expect(request.headers['authorization'], 'Bearer ${'x' * 43}');
        expect(
          request.url.path,
          '/api/v1/capability-evidence/${context.coreId}/${context.homeId}/records',
        );
        page++;
        if (page == 1) {
          expect(request.url.queryParameters, {'limit': '50'});
          return jsonResponse({
            'schemaVersion': 1,
            'scope': context.toJson(),
            'records': [recordJson('tested', id: '0' * 32)],
            'nextAfter': '0' * 32,
          });
        }
        expect(request.url.queryParameters, {'limit': '50', 'after': '0' * 32});
        return jsonResponse({
          'schemaVersion': 1,
          'scope': context.toJson(),
          'records': [recordJson('manual_required', id: '1' * 32)],
          'nextAfter': null,
        });
      }),
    );
    addTearDown(transport.close);
    final records = await CapabilityEvidenceApi(
      transport,
      'x' * 43,
      context,
    ).list();
    expect(records.map((record) => record.id), ['0' * 32, '1' * 32]);
    expect(page, 2);

    final drift = LarenorServerApi(
      endpoint: ServerEndpoint('https://core.invalid'),
      client: MockClient(
        (_) async => jsonResponse({
          'schemaVersion': 1,
          'scope': context.toJson(),
          'records': [
            {...recordJson('tested'), 'secret': 'must-not-enter-contract'},
          ],
          'nextAfter': null,
        }),
      ),
    );
    addTearDown(drift.close);
    await expectLater(
      CapabilityEvidenceApi(drift, 'x' * 43, context).list(),
      throwsA(
        isA<LarenorServerException>().having(
          (error) => error.code,
          'code',
          'invalid_response',
        ),
      ),
    );
  });

  test(
    'Core adapter requires exact page keys and enforces 256 total records',
    () async {
      final context = serverContext();

      LarenorServerApi transportFor(int total, {bool omitCursor = false}) {
        return LarenorServerApi(
          endpoint: ServerEndpoint('https://core.invalid'),
          client: MockClient((request) async {
            final after = request.url.queryParameters['after'];
            final start = after == null ? 0 : int.parse(after, radix: 16) + 1;
            final remaining = total - start;
            final count = remaining.clamp(0, 50);
            final records = List.generate(
              count,
              (offset) => recordJson(
                'tested',
                id: (start + offset).toRadixString(16).padLeft(32, '0'),
              ),
            );
            final consumed = start + count;
            return jsonResponse({
              'schemaVersion': 1,
              'scope': context.toJson(),
              'records': records,
              if (!omitCursor)
                'nextAfter': consumed < total ? records.last['id'] : null,
            });
          }),
        );
      }

      final accepted = transportFor(256);
      addTearDown(accepted.close);
      expect(
        await CapabilityEvidenceApi(accepted, 'x' * 43, context).list(),
        hasLength(256),
      );

      final oversized = transportFor(257);
      addTearDown(oversized.close);
      await expectLater(
        CapabilityEvidenceApi(oversized, 'x' * 43, context).list(),
        throwsA(
          isA<LarenorServerException>().having(
            (error) => error.code,
            'code',
            'invalid_response',
          ),
        ),
      );

      final missingCursor = transportFor(1, omitCursor: true);
      addTearDown(missingCursor.close);
      await expectLater(
        CapabilityEvidenceApi(missingCursor, 'x' * 43, context).list(),
        throwsA(isA<LarenorServerException>()),
      );
    },
  );

  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1280.0]) {
      testWidgets(
        '${locale.languageCode} $width 2x shows manual evidence without promotion',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 900);
          addTearDown(tester.view.reset);
          final controller = CapabilityEvidenceController(
            load: () async => [
              CapabilityEvidenceRecord.fromJson(recordJson('manual_required')),
            ],
            current: () => true,
          );
          addTearDown(controller.dispose);
          await tester.pumpWidget(
            CupertinoApp(
              locale: locale,
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: CapabilityEvidenceScreen(controller: controller),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('capability-evidence-manual-required')),
            findsOneWidget,
          );
          expect(find.text('Huawei'), findsOneWidget);
          expect(find.textContaining('k14-huawei'), findsOneWidget);
          final refresh = find.byKey(
            const ValueKey('capability-evidence-refresh'),
          );
          expect(tester.getSize(refresh).height, greaterThanOrEqualTo(48));
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(controller.loadCount, 2);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'late response after authority loss is discarded and old proof is hidden',
    (tester) async {
      final pending = Completer<List<CapabilityEvidenceRecord>>();
      var current = true;
      final controller = CapabilityEvidenceController(
        load: () => pending.future,
        current: () => current,
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: CapabilityEvidenceScreen(controller: controller),
        ),
      );
      await tester.pump();
      current = false;
      controller.invalidate();
      pending.complete([
        CapabilityEvidenceRecord.fromJson(recordJson('tested')),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('Huawei'), findsNothing);
      expect(controller.records, isEmpty);
    },
  );
}
