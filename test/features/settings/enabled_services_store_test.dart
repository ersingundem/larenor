import 'package:flutter_test/flutter_test.dart';
import 'package:oikos/features/settings/data/app_service.dart';
import 'package:oikos/features/settings/data/enabled_services_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('read returns an empty set when nothing is saved', () async {
    final services = await EnabledServicesStore().read();
    expect(services, isEmpty);
  });

  test('save then read round-trips the enabled set', () async {
    final store = EnabledServicesStore();
    await store.save({AppService.jellyfin, AppService.proxmox});

    final read = await store.read();
    expect(read, {AppService.jellyfin, AppService.proxmox});
  });

  test('ignores unknown/stale enum names stored by a prior version', () async {
    SharedPreferences.setMockInitialValues({
      'enabled_services': ['jellyfin', 'some_removed_service'],
    });

    final services = await EnabledServicesStore().read();
    expect(services, {AppService.jellyfin});
  });
}
