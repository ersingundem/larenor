import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_config.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_track_preferences_store.dart';
import 'package:larenor/features/media/jellyfin/data/legacy_jellyfin_track_preferences_controller.dart';
import 'package:larenor/features/media/jellyfin/data/legacy_jellyfin_track_preferences_preview.dart';
import 'package:larenor/features/media/jellyfin/presentation/legacy_jellyfin_track_preferences_migration_card.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _config = JellyfinConfig(
  baseUrl: 'https://private-jellyfin.invalid/root',
  userId: 'private-user-id',
  accessToken: 'private-access-token',
  deviceId: 'private-device-id',
);

String _legacyKey() {
  final scope = sha256.convert(
    utf8.encode('${_config.baseUrl}\u0000${_config.userId}'),
  );
  return 'jellyfin_track_languages_v1_$scope';
}

Future<LegacyJellyfinTrackPreferencesMigrationController> _mount(
  WidgetTester tester, {
  required String language,
  required double width,
}) async {
  SharedPreferences.setMockInitialValues({
    _legacyKey(): jsonEncode({'version': 1, 'audio': 'tur', 'subtitle': 'off'}),
  });
  final controller = LegacyJellyfinTrackPreferencesMigrationController(
    migration: LegacyJellyfinTrackPreferencesMigration(
      core: JellyfinTrackPreferencesStore(),
    ),
    config: _config,
    isCurrent: () => true,
  );
  await controller.start();
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    CupertinoApp(
      locale: Locale(language),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MediaQuery(
        data: MediaQueryData.fromView(tester.view)
            .copyWith(textScaler: const TextScaler.linear(2)),
        child: CupertinoPageScaffold(
          child: SafeArea(
            child: LegacyJellyfinTrackPreferencesMigrationCard(
              controller: controller,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final width in [600.0, 1200.0]) {
    for (final language in ['en', 'tr']) {
      testWidgets(
        'explicit migration is accessible at ${width.toInt()} $language 2x',
        (tester) async {
          final semantics = tester.ensureSemantics();
          final controller = await _mount(
            tester,
            language: language,
            width: width,
          );

          expect(tester.takeException(), isNull);
          expect(
            find.text(
              language == 'tr'
                  ? 'Eski dil tercihleri bulundu'
                  : 'Previous language preferences found',
            ),
            findsOneWidget,
          );
          final confirm = find.byKey(
            const ValueKey('legacy-track-preferences-confirm'),
          );
          final cancel = find.byKey(
            const ValueKey('legacy-track-preferences-cancel'),
          );
          expect(confirm, findsOneWidget);
          expect(cancel, findsOneWidget);
          expect(tester.getSize(confirm).height, greaterThanOrEqualTo(48));
          expect(tester.getSize(cancel).height, greaterThanOrEqualTo(48));
          expect(tester.getSemantics(confirm).flagsCollection.isButton, isTrue);
          expect(tester.getSemantics(cancel).flagsCollection.isButton, isTrue);
          expect(find.textContaining(_config.accessToken), findsNothing);
          expect(find.textContaining(_config.baseUrl), findsNothing);

          await tester.tap(cancel);
          await tester.pump();
          expect(
            controller.state.phase,
            LegacyJellyfinTrackPreferencesMigrationPhase.dismissed,
          );
          expect(
            (await SharedPreferences.getInstance()).containsKey(_legacyKey()),
            isTrue,
          );
          expect(tester.takeException(), isNull);
          semantics.dispose();
        },
      );
    }
  }
}
