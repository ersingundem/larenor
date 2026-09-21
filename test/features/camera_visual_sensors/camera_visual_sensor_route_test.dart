import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/camera_visual_sensors/presentation/camera_visual_sensor_route.dart';
import 'package:larenor/features/camera_visual_sensors/presentation/camera_visual_sensor_screen.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/features/settings/presentation/settings_split_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import '../server/server_admin_test_support.dart';

Map<String, Object?> _summary() => {
  'schemaVersion': 1,
  'scope': {'schemaVersion': 1, 'coreId': 'a' * 32, 'homeId': 'b' * 32},
  'capability': {
    'schemaVersion': 1,
    'architecture': 'arm64',
    'avx': 'not_applicable',
    'avx2': 'not_applicable',
    'arm64': true,
    'detectorState': 'unavailable',
    'trainingSupported': false,
    'inferenceSupported': false,
    'reason': 'arm64_unverified',
  },
  'rules': <Object?>[],
};

void main() {
  late AdminFixture fixture;

  Future<void> mount(
    WidgetTester tester,
    Widget home, {
    String language = 'en',
    double width = 600,
    bool settle = true,
  }) async {
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
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: home,
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  setUp(() async {
    fixture = AdminFixture();
    fixture.respond = (request) async {
      if (request.url.path.contains('/camera-visual-sensors/')) {
        return fixture.json(_summary());
      }
      return fixture.defaultResponse(request);
    };
    await fixture.account.initialize();
  });

  tearDown(() => fixture.account.dispose());

  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1280.0]) {
      testWidgets('Settings discovers visual sensors $language $width at 2x', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        try {
          await mount(
            tester,
            SettingsSplitScreen(visualSensorGateCurrent: () => true),
            language: language,
            width: width,
          );
          final entry = find
              .text(
                language == 'tr'
                    ? 'Kamera görsel sensörleri'
                    : 'Camera visual sensors',
              )
              .first;
          await tester.ensureVisible(entry);
          final button = find.ancestor(
            of: entry,
            matching: find.byType(CupertinoButton),
          );
          expect(tester.getSemantics(button).flagsCollection.isButton, isTrue);
          expect(tester.getRect(button).height, greaterThanOrEqualTo(48));
          Focus.of(tester.element(entry)).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(find.byType(CameraVisualSensorRoute), findsOneWidget);
          expect(find.byType(CameraVisualSensorScreen), findsOneWidget);
          final calls = fixture.calls.where(
            (call) => call.url.path.contains('/camera-visual-sensors/'),
          );
          expect(calls, hasLength(1));
          expect(
            calls.single.headers['authorization'],
            'Bearer synthetic_admin_access_12345',
          );
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });
    }
  }

  testWidgets('gate and account changes retire late callbacks', (tester) async {
    await mount(tester, CameraVisualSensorRoute(gateCurrent: () => false));
    expect(find.byType(CameraVisualSensorScreen), findsNothing);
    expect(
      fixture.calls.where(
        (call) => call.url.path.contains('/camera-visual-sensors/'),
      ),
      isEmpty,
    );

    final delayed = Completer<http.Response>();
    fixture.respond = (request) async {
      if (request.url.path.contains('/camera-visual-sensors/')) {
        return delayed.future;
      }
      return fixture.defaultResponse(request);
    };
    await tester.pumpWidget(const SizedBox.shrink());
    await mount(
      tester,
      CameraVisualSensorRoute(gateCurrent: () => true),
      settle: false,
    );
    await tester.pump();
    unawaited(fixture.account.signOut());
    delayed.complete(fixture.json(_summary()));
    await tester.pumpAndSettle();
    expect(find.byType(CameraVisualSensorScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
