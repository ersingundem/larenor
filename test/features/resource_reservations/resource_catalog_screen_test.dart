import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/resource_reservations/data/resource_catalog_controller.dart';
import 'package:larenor/features/resource_reservations/domain/resource_reservation_models.dart';
import 'package:larenor/features/resource_reservations/presentation/resource_catalog_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

final class CatalogApi implements ResourceCatalogApi {
  int updates = 0;
  @override
  Future<ResourceCatalogSnapshot> resources() async => ResourceCatalogSnapshot(
    catalogRevision: 1,
    canManage: true,
    resources: const [
      ReservationResource(
        id: 'one',
        revision: 1,
        label: 'Guest room',
        timezone: 'UTC',
        capacity: 1,
      ),
      ReservationResource(
        id: 'two',
        revision: 1,
        label: 'Workshop',
        timezone: 'Europe/Istanbul',
        capacity: 2,
      ),
    ],
  );
  @override
  Future<ResourceCatalogReceipt> createResource({
    required int expectedCatalogRevision,
    required String commandId,
    required String label,
    required String timezone,
    required int capacity,
  }) async => ResourceCatalogReceipt(
    catalogRevision: 2,
    resource: ReservationResource(
      id: 'three',
      revision: 1,
      label: label,
      timezone: timezone,
      capacity: capacity,
    ),
  );
  @override
  Future<ResourceCatalogReceipt> updateResource({
    required int expectedCatalogRevision,
    required String commandId,
    required ReservationResource resource,
    required String label,
    required String timezone,
    required int capacity,
  }) async {
    updates++;
    return ResourceCatalogReceipt(
      catalogRevision: expectedCatalogRevision + 1,
      resource: ReservationResource(
        id: resource.id,
        revision: resource.revision + 1,
        label: label,
        timezone: timezone,
        capacity: capacity,
      ),
    );
  }

  @override
  Future<ResourceCatalogReceipt> deactivateResource({
    required int expectedCatalogRevision,
    required String commandId,
    required ReservationResource resource,
  }) async => ResourceCatalogReceipt(
    catalogRevision: expectedCatalogRevision + 1,
    resource: ReservationResource(
      id: resource.id,
      revision: resource.revision + 1,
      label: resource.label,
      timezone: resource.timezone,
      capacity: resource.capacity,
      active: false,
    ),
  );
}

void main() {
  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets('catalog is accessible at $language $width 2x', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        final api = CatalogApi();
        final controller = ResourceCatalogController(
          api,
          commandIds: () => '1' * 32,
        );
        await tester.pumpWidget(
          CupertinoApp(
            locale: Locale(language),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(width, 1000),
                textScaler: const TextScaler.linear(2),
              ),
              child: ResourceCatalogScreen(controller: controller),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final save = find.byKey(const ValueKey('resource-catalog-save'));
        expect(save, findsOneWidget);
        expect(tester.getRect(save).height, greaterThanOrEqualTo(48));
        final row = find.byKey(const ValueKey('resource-catalog-one'));
        expect(tester.getRect(row).height, greaterThanOrEqualTo(48));
        expect(tester.getSemantics(row).flagsCollection.isButton, isTrue);
        await tester.tap(row);
        await tester.pump();
        final label = find.byKey(const ValueKey('resource-catalog-label'));
        await tester.enterText(label, 'Updated room');
        final keyboardTarget = find.descendant(
          of: save,
          matching: find.byType(FocusableActionDetector),
        );
        Actions.invoke(
          tester.element(keyboardTarget.last),
          const ActivateIntent(),
        );
        await tester.pumpAndSettle();
        expect(api.updates, 1);
        expect(tester.takeException(), isNull);
        semantics.dispose();
      });
    }
  }
}
