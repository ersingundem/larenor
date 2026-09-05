import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/configuration_writes.dart';
import 'package:larenor/features/dashboard/data/dashboard_repository.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/dashboard/providers/dashboard_providers.dart';
import 'package:larenor/features/web_panel/domain/web_panel_options.dart';
import 'package:shared_preferences/shared_preferences.dart';

const initial = TileConfig(
  id: 'web',
  type: TileType.webview,
  x: 0,
  y: 0,
  width: 2,
  height: 2,
  url: 'https://panel.invalid',
);
void main() {
  late ProviderContainer container;
  late DashboardRepository repository;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    repository = DashboardRepository();
    await repository.save(const DashboardLayout(tiles: [initial]));
    container = ProviderContainer(
      overrides: [dashboardRepositoryProvider.overrideWithValue(repository)],
    );
    container.listen(dashboardLayoutProvider, (_, _) {});
    await container.read(dashboardLayoutProvider.future);
  });
  tearDown(() => container.dispose());
  test('source options persist without replacing placement or unrelated tile fields', () async {
    final next = initial.copyWith(
      url: 'https://panel.invalid/new',
      webPanel: WebPanelOptions(
        additionalOrigins: ['https://login.invalid'],
        textZoom: 150,
      ),
    );
    await container
        .read(dashboardLayoutProvider.notifier)
        .updateTile(next, expectedTile: initial, isCurrent: () => true);
    expect((await repository.load()).tiles.single, next);
  });
  test(
    'stale expected tile cannot overwrite concurrent resize or deletion',
    () async {
      final notifier = container.read(dashboardLayoutProvider.notifier);
      await notifier.updateTile(initial.copyWith(width: 3));
      await expectLater(
        notifier.updateTile(
          initial.copyWith(url: 'https://new.invalid'),
          expectedTile: initial,
        ),
        throwsException,
      );
      expect((await repository.load()).tiles.single.width, 3);
      await notifier.removeTile(initial.id);
      await expectLater(
        notifier.updateTile(initial, expectedTile: initial),
        throwsException,
      );
      expect((await repository.load()).tiles, isEmpty);
    },
  );
  test(
    'queued source edit checks current session after lock before writing',
    () async {
      final gate = Completer<void>();
      final started = Completer<void>();
      final blocked = ConfigurationWrites.run(() {
        started.complete();
        return gate.future;
      });
      await started.future;
      var current = true;
      final edit = container
          .read(dashboardLayoutProvider.notifier)
          .updateTile(
            initial.copyWith(url: 'https://new.invalid'),
            expectedTile: initial,
            isCurrent: () => current,
          );
      final assertion = expectLater(edit, throwsException);
      current = false;
      gate.complete();
      await blocked;
      await assertion;
      expect((await repository.load()).tiles.single, initial);
    },
  );
}
