import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
// Uses the pinned secure-storage plugin's public platform test seam.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/router.dart';
import 'package:larenor/features/auth/data/credentials_store.dart';
import 'package:larenor/features/auth/data/ha_discovery.dart';
import 'package:larenor/features/auth/presentation/connect_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NoDiscovery extends HaDiscoveryService {
  @override
  Future<void> start() async {}
}

void main() {
  for (final locale in ['en', 'tr']) {
    testWidgets(
      'pending HA recovery offers empty explicit connection form $locale',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        FlutterSecureStorage.setMockInitialValues({
          CredentialsStore.pendingMutationKey: '1',
          'ha_base_url': 'https://old-private.invalid',
          'ha_token': 'old-private-secret',
        });
        final container = ProviderContainer(
          overrides: [
            haDiscoveryFactoryProvider.overrideWithValue(_NoDiscovery.new),
          ],
          retry: (_, _) => null,
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: CupertinoApp.router(
              locale: Locale(locale),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              routerConfig: container.read(routerProvider),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(ConnectScreen), findsOneWidget);
        final fields = tester.widgetList<CupertinoTextField>(
          find.byType(CupertinoTextField),
        );
        expect(fields, hasLength(2));
        expect(fields.map((f) => f.controller!.text), everyElement(isEmpty));
        final l10n = AppLocalizations.of(
          tester.element(find.byType(ConnectScreen)),
        );
        expect(
          find.widgetWithText(CupertinoButton, l10n.commonConnect),
          findsOneWidget,
        );
        expect(find.textContaining('old-private'), findsNothing);
        expect(
          await const FlutterSecureStorage().read(
            key: CredentialsStore.pendingMutationKey,
          ),
          '1',
        );
        await tester.pump(const Duration(seconds: 7));
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'unconfirmed platform storage error does not open recovery form',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final previous = FlutterSecureStoragePlatform.instance;
      FlutterSecureStoragePlatform.instance =
          MethodChannelFlutterSecureStorage();
      const channel = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
            throw const FormatException('sentinel-private-platform-value');
          });
      addTearDown(() {
        FlutterSecureStoragePlatform.instance = previous;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      final container = ProviderContainer(retry: (_, _) => null);
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: CupertinoApp.router(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: container.read(routerProvider),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ConnectScreen), findsNothing);
      expect(find.byType(CupertinoTextField), findsNothing);
      expect(find.textContaining('sentinel'), findsNothing);
      expect(
        find.text('Secure storage is unavailable. Settings remain locked.'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
