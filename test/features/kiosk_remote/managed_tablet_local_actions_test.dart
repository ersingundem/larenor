import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/dashboard/data/dashboard_repository.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/providers/dashboard_providers.dart';
import 'package:larenor/features/kiosk_remote/runtime/managed_tablet_runtime_scope.dart';

final class _Repository extends DashboardRepository {
  int loads = 0;

  @override
  Future<DashboardLayout> load() async {
    loads++;
    return const DashboardLayout();
  }
}

void main() {
  test('production action reloads the dashboard only while current', () async {
    final repository = _Repository();
    final container = ProviderContainer(
      overrides: [dashboardRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(dashboardLayoutProvider, (_, _) {});
    addTearDown(subscription.close);
    await container.read(dashboardLayoutProvider.future);
    expect(repository.loads, 1);

    final actions = container.read(managedTabletLocalActionsProvider);
    await actions.refreshDashboard(isCurrent: () => true);
    expect(repository.loads, 2);

    await expectLater(
      actions.refreshDashboard(isCurrent: () => false),
      throwsStateError,
    );
    expect(repository.loads, 2);
  });
}
