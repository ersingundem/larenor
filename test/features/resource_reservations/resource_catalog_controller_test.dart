import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/resource_reservations/data/resource_catalog_controller.dart';
import 'package:larenor/features/resource_reservations/domain/resource_reservation_models.dart';

const first = ReservationResource(
  id: 'resource-one',
  revision: 1,
  label: 'Guest room',
  timezone: 'UTC',
  capacity: 1,
);
const second = ReservationResource(
  id: 'resource-two',
  revision: 1,
  label: 'Workshop',
  timezone: 'Europe/Istanbul',
  capacity: 2,
);

final class FakeCatalogApi implements ResourceCatalogApi {
  final loads = <Completer<ResourceCatalogSnapshot>>[];
  int creates = 0, updates = 0, deactivates = 0;
  bool timeoutCreate = false;

  @override
  Future<ResourceCatalogSnapshot> resources() {
    final value = Completer<ResourceCatalogSnapshot>();
    loads.add(value);
    return value.future;
  }

  @override
  Future<ResourceCatalogReceipt> createResource({
    required int expectedCatalogRevision,
    required String commandId,
    required String label,
    required String timezone,
    required int capacity,
  }) async {
    creates++;
    if (timeoutCreate) throw TimeoutException('lost ack');
    return ResourceCatalogReceipt(
      catalogRevision: expectedCatalogRevision + 1,
      resource: ReservationResource(
        id: 'created',
        revision: 1,
        label: label,
        timezone: timezone,
        capacity: capacity,
      ),
    );
  }

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
  }) async {
    deactivates++;
    return ResourceCatalogReceipt(
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
}

ResourceCatalogSnapshot snapshot({
  int revision = 1,
  bool canManage = true,
  List<ReservationResource> resources = const [first, second],
}) => ResourceCatalogSnapshot(
  catalogRevision: revision,
  canManage: canManage,
  resources: resources,
);

void main() {
  test(
    'late catalog response is discarded after authority retirement',
    () async {
      final api = FakeCatalogApi();
      final controller = ResourceCatalogController(
        api,
        commandIds: () => '1' * 32,
      );
      final lease = controller.bind();
      controller.retire();
      api.loads.single.complete(snapshot());
      await Future<void>.delayed(Duration.zero);
      expect(controller.state, ResourceCatalogState.detached);
      expect(controller.resources, isEmpty);
      expect(lease, 1);
    },
  );

  test(
    'exact create update and deactivate advance one catalog revision',
    () async {
      final api = FakeCatalogApi();
      final controller = ResourceCatalogController(
        api,
        commandIds: () => '2' * 32,
      );
      final lease = controller.bind();
      api.loads.single.complete(snapshot());
      await Future<void>.delayed(Duration.zero);
      await controller.create(
        lease,
        label: 'Office',
        timezone: 'Europe/Berlin',
        capacity: 3,
      );
      expect(controller.revision, 2);
      final created = controller.resources.singleWhere(
        (item) => item.id == 'created',
      );
      await controller.update(
        lease,
        created,
        label: 'Office two',
        timezone: 'Europe/Berlin',
        capacity: 4,
      );
      expect(controller.revision, 3);
      final changed = controller.resources.singleWhere(
        (item) => item.id == 'created',
      );
      await controller.deactivate(lease, changed);
      expect(controller.revision, 4);
      expect(
        controller.resources.singleWhere((item) => item.id == 'created').active,
        isFalse,
      );
      expect((api.creates, api.updates, api.deactivates), (1, 1, 1));
    },
  );

  test(
    'lost acknowledgement is visible and never automatically replayed',
    () async {
      final api = FakeCatalogApi()..timeoutCreate = true;
      final controller = ResourceCatalogController(
        api,
        commandIds: () => '3' * 32,
      );
      final lease = controller.bind();
      api.loads.single.complete(snapshot());
      await Future<void>.delayed(Duration.zero);
      await controller.create(
        lease,
        label: 'Office',
        timezone: 'UTC',
        capacity: 1,
      );
      expect(controller.state, ResourceCatalogState.uncertain);
      expect(api.creates, 1);
      await controller.create(
        lease,
        label: 'Office',
        timezone: 'UTC',
        capacity: 1,
      );
      expect(api.creates, 1);
    },
  );
}
