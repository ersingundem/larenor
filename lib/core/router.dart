import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/dashboard/presentation/home_dashboard_screen.dart';
import '../features/media/hub/domain/media_title.dart';
import '../features/media/hub/presentation/media_hub_screen.dart';
import '../features/navigation/presentation/app_shell.dart';
import '../features/navigation/presentation/destination_screens.dart';
import '../features/navigation/presentation/routines_screen.dart';
import '../features/navigation/presentation/system_screen.dart';
import '../features/navigation/search/domain/navigation_target.dart';
import '../features/navigation/search/presentation/local_search_screen.dart';
import '../features/settings/data/app_service.dart';
import '../features/settings/presentation/settings_gate_screen.dart';
import '../features/intercom/presentation/intercom_screen.dart';
import '../features/today/presentation/today_screen.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final rootKey = GlobalKey<NavigatorState>();
  final router = GoRouter(
    navigatorKey: rootKey,
    initialLocation: '/',
    errorBuilder: (_, _) => const MissingDestinationScreen(),
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) =>
            AppShell(navigationShell: shell, location: state.uri),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/',
                builder: (_, _) => const HomeDashboardScreen(embedded: true),
                routes: [
                  GoRoute(
                    path: 'today',
                    builder: (_, _) => const TodayScreen(),
                  ),
                  GoRoute(
                    path: 'intercom',
                    builder: (_, _) => const IntercomScreen(),
                  ),
                  GoRoute(
                    path: 'rooms/:roomId',
                    builder: (_, state) => RoomDestinationScreen(
                      roomId: state.pathParameters['roomId']!,
                    ),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/media',
                builder: (_, _) => const MediaHubScreen(embedded: true),
                routes: [
                  GoRoute(
                    path: 'title',
                    builder: (_, state) => MediaDestinationScreen(
                      location: state.uri,
                      snapshot: state.extra is MediaTitle
                          ? state.extra as MediaTitle
                          : null,
                    ),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/routines',
                builder: (_, _) => const RoutinesScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/system',
                builder: (_, _) => const SystemScreen(),
                routes: [
                  GoRoute(
                    path: ':service',
                    builder: (_, state) {
                      final service = AppService.values
                          .where(
                            (v) => v.name == state.pathParameters['service'],
                          )
                          .firstOrNull;
                      return service == null
                          ? const MissingDestinationScreen()
                          : OperationalServiceScreen(service: service);
                    },
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/entities/:entityId',
        builder: (_, state) => EntityDestinationScreen(
          entityId: state.pathParameters['entityId']!,
        ),
      ),
      GoRoute(
        path: '/search',
        builder: (context, _) => LocalSearchScreen(
          onOpenTarget: (target) {
            if (target is EntityNavigationTarget) {
              context.push(target.location);
            } else {
              context.go(
                target.location,
                extra: target is MediaNavigationTarget ? target.snapshot : null,
              );
            }
          },
        ),
      ),
      GoRoute(path: '/settings', builder: (_, _) => const SettingsGateScreen()),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
