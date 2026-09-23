import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/features/server/services/presentation/server_services_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server_services_test.dart';

Map<String, dynamic> _policy({
  int revision = 0,
  List<Map<String, dynamic>> grants = const [],
}) => {
  'schemaVersion': 2,
  'policy': {
    'component': 'home_assistant_probe',
    'serviceId': serviceId,
    'serviceRevision': 1,
    'revision': revision,
    'grants': grants,
  },
  'audit': <Map<String, dynamic>>[],
};

Map<String, dynamic> _grant() => {
  'scheme': 'https',
  'host': 'media.example.test',
  'port': 443,
  'addresses': [
    {'address': '192.168.1.150', 'network': 'lan'},
    {'address': '10.20.30.40', 'network': 'lan'},
  ],
};

Map<String, dynamic> _resolution() => {
  'schemaVersion': 1,
  'serviceId': serviceId,
  'serviceRevision': 1,
  'component': 'home_assistant_probe',
  'grant': _grant(),
};

class _Fixture extends ServicesFixture {
  _Fixture() {
    respond = (request) async {
      if (request.url.path.contains('/outbound-policy')) {
        return egressResponse(request);
      }
      return serviceResponse(request);
    };
  }

  var policyRevision = 0;
  List<Map<String, dynamic>> grants = [];

  http.Response egressResponse(http.Request request) {
    if (request.method == 'GET') {
      return this.json(_policy(revision: policyRevision, grants: grants));
    }
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    if (request.url.path.endsWith('/outbound-policy/resolve')) {
      if (body.length != 1 || body['expectedServiceRevision'] != 1) {
        return this.json({
          'error': {'code': 'revision_conflict'},
        }, 409);
      }
      return this.json(_resolution());
    }
    if (body.keys.toSet().difference({
          'expectedRevision',
          'expectedServiceRevision',
          'grants',
        }).isNotEmpty ||
        body['expectedRevision'] != policyRevision ||
        body['expectedServiceRevision'] != 1) {
      return this.json({
        'error': {'code': 'revision_conflict'},
      }, 409);
    }
    policyRevision++;
    grants = (body['grants'] as List)
        .map((value) => Map<String, dynamic>.from(value as Map))
        .toList();
    return this.json(_policy(revision: policyRevision, grants: grants));
  }
}

void main() {
  late _Fixture fixture;

  Future<void> mount(
    WidgetTester tester, {
    String kind = 'home_assistant',
    double width = 600,
    double scale = 1,
    String language = 'en',
  }) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'settings_pin': '1234'});
    fixture = _Fixture()
      ..records.add({...serviceJson(), 'kind': kind, 'name': 'Home'});
    await fixture.account.initialize();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 1000);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(fixture.account),
        ],
        child: CupertinoApp(
          locale: Locale(language),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const ServerServicesScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.account.dispose();
    });
  }

  Future<void> tap(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('supported service exposes policy without an automatic write', (
    tester,
  ) async {
    await mount(tester);
    expect(find.byKey(ValueKey('service-egress-$serviceId')), findsOneWidget);
    await tap(tester, 'service-egress-$serviceId');
    expect(find.byKey(const ValueKey('egress-addresses')), findsOneWidget);
    expect(find.text('Blocked'), findsOneWidget);
    expect(fixture.mutations, isEmpty);
    expect(
      fixture.adminCalls.where(
        (call) => call.url.path.endsWith('/outbound-policy'),
      ),
      hasLength(1),
    );
  });

  testWidgets('reviewed pins replace and clear the exact policy revision', (
    tester,
  ) async {
    await mount(tester);
    await tap(tester, 'service-egress-$serviceId');
    await tester.enterText(
      find.byKey(const ValueKey('egress-addresses')),
      '192.168.1.150\n10.20.30.40',
    );
    await tap(tester, 'egress-save');
    expect(fixture.policyRevision, 0);
    expect(
      find.text('Resolve and review the current addresses before saving them.'),
      findsOneWidget,
    );
    expect(fixture.mutations, isEmpty);
    await tap(tester, 'egress-resolve');
    expect(jsonDecode(fixture.mutations.single.body), {
      'expectedServiceRevision': 1,
    });
    expect(
      find.text('Addresses resolved by Core for this exact service revision.'),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('egress-addresses')),
      '192.168.1.150',
    );
    expect(
      find.text('Addresses resolved by Core for this exact service revision.'),
      findsNothing,
    );
    await tap(tester, 'egress-save');
    expect(fixture.policyRevision, 0);
    expect(
      find.text('Resolve and review the current addresses before saving them.'),
      findsOneWidget,
    );
    await tap(tester, 'egress-resolve');
    await tap(tester, 'egress-save');
    expect(fixture.policyRevision, 1);
    expect(fixture.grants.single, _grant());
    expect(find.text('Allowed for 2 pinned addresses'), findsOneWidget);
    await tap(tester, 'egress-disable');
    expect(fixture.policyRevision, 2);
    expect(fixture.grants, isEmpty);
    expect(find.text('Blocked'), findsOneWidget);
  });

  testWidgets('unsupported services have no policy action or request', (
    tester,
  ) async {
    await mount(tester, kind: 'jellyfin');
    expect(find.byKey(ValueKey('service-egress-$serviceId')), findsNothing);
    expect(
      fixture.adminCalls.where(
        (call) => call.url.path.endsWith('/outbound-policy'),
      ),
      isEmpty,
    );
  });

  for (final language in ['en', 'tr']) {
    testWidgets('tablet dialog stays usable at 2x text in $language', (
      tester,
    ) async {
      await mount(tester, width: 600, scale: 2, language: language);
      await tap(tester, 'service-egress-$serviceId');
      final field = find.byKey(const ValueKey('egress-addresses'));
      expect(field, findsOneWidget);
      expect(tester.getSize(field).height, greaterThanOrEqualTo(96));
      await tester.ensureVisible(find.byKey(const ValueKey('egress-save')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('egress-save')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
