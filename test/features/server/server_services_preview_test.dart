import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/features/server/services/presentation/server_services_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server_services_test.dart';

void main() {
  for (final form in [false, true]) {
    testWidgets('tablet services ${form ? 'form' : 'list'} visual fixture', (
      tester,
    ) async {
      const directory = String.fromEnvironment('SERVICES_PREVIEW_DIR');
      if (directory.isNotEmpty) {
        await tester.runAsync(() async {
          final font = await rootBundle.load('assets/fonts/Inter-Variable.ttf');
          for (final family in [
            'Inter',
            'CupertinoSystemText',
            'CupertinoSystemDisplay',
          ]) {
            await (FontLoader(family)..addFont(Future.value(font))).load();
          }
          await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(
                rootBundle.load(
                  'packages/cupertino_icons/assets/CupertinoIcons.ttf',
                ),
              ))
              .load();
        });
      }
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({'settings_pin': '1234'});
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fixture = ServicesFixture();
      fixture.records.addAll([
        {
          ...serviceJson(state: 'authenticated'),
          'name': 'Ev otomasyonu',
          'kind': 'home_assistant',
          'baseUrl': 'https://home.example.test',
          'verification': {
            ...serviceJson(state: 'authenticated')['verification'],
            'version': '2026.9.1',
          },
        },
        {
          ...serviceJson(state: 'reachable'),
          'id': 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
          'name': 'Salon medya',
          'credentialKeys': [],
        },
        {
          ...serviceJson(),
          'id': 'ffffffffffffffffffffffffffffffff',
          'name': 'Fotoğraf arşivi',
          'kind': 'immich',
          'baseUrl': 'https://photos.example.test',
          'credentialKeys': ['apiKey'],
        },
      ]);
      await fixture.account.initialize();
      final boundary = GlobalKey();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            serverAccountControllerProvider.overrideWithValue(fixture.account),
          ],
          child: CupertinoApp(
            locale: const Locale('tr'),
            theme: larenorTheme(
              brightness: form ? Brightness.light : Brightness.dark,
            ),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (_, child) =>
                RepaintBoundary(key: boundary, child: child!),
            home: const ServerServicesScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (form) {
        await tester.tap(find.byKey(ValueKey('service-edit-$serviceId')));
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      expect(fixture.mutations, isEmpty);
      if (directory.isNotEmpty) {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await render.toImage();
          try {
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              '$directory/server-services-tablet-${form ? 'form' : 'list'}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      }
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.account.dispose();
    });
  }
}
