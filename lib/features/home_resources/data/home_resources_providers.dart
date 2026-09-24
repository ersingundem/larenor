import 'package:flutter_riverpod/legacy.dart';

import '../../../core/home_session_controller.dart';
import 'home_resources_api.dart';
import 'home_resources_controller.dart';

/// Account-scoped resource metadata shared by search, rooms and dashboard
/// cards. Same-runtime rows remain visible during refresh, but are marked
/// stale and cannot authorize an action. Account/Core/home replacement tears
/// down the whole home runtime before another identity can observe them.
final sharedHomeResourcesProvider =
    ChangeNotifierProvider<HomeResourcesController?>((ref) {
      final home = ref.watch(homeSessionControllerProvider);
      if (home == null) return null;
      final controller = HomeResourcesController(
        home,
        ref.watch(homeResourcesApiFactoryProvider),
        ref.watch(homeResourcesClockProvider),
        () => true,
        retainSameRuntimeRows: true,
        loadEveryPage: true,
      );
      controller.setVisible(true);
      return controller;
    });
