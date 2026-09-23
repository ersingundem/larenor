import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/dashboard/presentation/home_dashboard_screen.dart';
import '../features/home_scope/presentation/core_home_status_screen.dart';
import 'home_session_controller.dart';
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
import '../features/inventory/presentation/inventory_route.dart';
import '../features/home_documents/presentation/home_documents_route.dart';
import '../features/family_board/presentation/family_board_route.dart';
import '../features/room_presence/presentation/room_presence_route.dart';
import '../features/resource_reservations/presentation/resource_reservation_route.dart';
import '../features/resource_reservations/presentation/resource_catalog_route.dart';
import '../features/irrigation_budget/presentation/irrigation_budget_route.dart';
import '../features/epaper/presentation/epaper_management_route.dart';
import '../features/floor_plan/presentation/floor_plan_route.dart';
import '../features/fair_chores/presentation/fair_chore_route.dart';
import '../features/local_notifications/presentation/local_notification_screen.dart';
import '../features/meal_planner/presentation/weekly_meal_plan_route.dart';
import '../features/shared_expenses/presentation/shared_expense_route.dart';
import '../features/today/presentation/today_screen.dart';
import '../features/energy/presentation/energy_maintenance_screen.dart';
import '../features/power_budget/presentation/power_budget_route.dart';
import '../features/media/ha_playback/presentation/ha_playback_screen.dart';
import '../features/media/music/presentation/music_center_screen.dart';
import '../features/media/local_audio/presentation/local_audio_screen.dart';
import '../features/server/music_manager/presentation/server_music_manager_screen.dart';
import '../features/wellbeing/presentation/wellbeing_gate.dart';
import '../features/camera_search/presentation/camera_search_route.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final rootKey = GlobalKey<NavigatorState>();
  final home = ref.read(homeSessionControllerProvider);
  if (home != null && !home.usesLocalHome) {
    final router = GoRouter(
      navigatorKey: rootKey,
      initialLocation: '/',
      errorBuilder: (_, _) => const CoreHomeStatusScreen(),
      routes: [
        GoRoute(path: '/', builder: (_, _) => const CoreHomeStatusScreen()),
        GoRoute(path: '/inventory', builder: (_, _) => const InventoryRoute()),
        GoRoute(path: '/floor-plan', builder: (_, _) => const FloorPlanRoute()),
        GoRoute(
          path: '/weekly-menu',
          builder: (_, _) => const WeeklyMealPlanRoute(),
        ),
        GoRoute(path: '/chores', builder: (_, _) => const FairChoreRoute()),
        GoRoute(
          path: '/documents',
          builder: (_, _) => const HomeDocumentsRoute(),
        ),
        GoRoute(
          path: '/reservations',
          builder: (_, _) => const ResourceReservationRoute(),
        ),
        GoRoute(
          path: '/reservations/manage',
          builder: (_, _) => const ResourceCatalogRoute(),
        ),
        GoRoute(
          path: '/family-board',
          builder: (_, _) => const FamilyBoardRoute(),
        ),
        GoRoute(
          path: '/notifications',
          builder: (_, _) => const LocalNotificationScreen(),
        ),
        GoRoute(
          path: '/epaper',
          builder: (_, _) => const EpaperManagementRoute(),
        ),
        GoRoute(
          path: '/room-presence',
          builder: (_, _) => const RoomPresenceRoute(),
        ),
        GoRoute(
          path: '/shared-expenses',
          builder: (_, _) => const SharedExpenseRoute(),
        ),
        GoRoute(
          path: '/camera-search',
          builder: (_, _) => const CameraSearchRoute(),
        ),
        GoRoute(
          path: '/media/music',
          builder: (_, _) => const ServerMusicManagerScreen(),
        ),
        GoRoute(
          path: '/settings',
          builder: (_, _) => const SettingsGateScreen(
            initialDestination: SettingsGateDestination.serverAccount,
          ),
        ),
        GoRoute(
          path: '/settings/tablet-fleet',
          builder: (_, _) => const SettingsGateScreen(
            initialDestination: SettingsGateDestination.tabletFleet,
          ),
        ),
        GoRoute(
          path: '/settings/home-source',
          builder: (_, _) => const SettingsGateScreen(
            initialDestination: SettingsGateDestination.homeSource,
          ),
        ),
        GoRoute(
          path: '/settings/kiosk',
          builder: (_, _) => const SettingsGateScreen(
            initialDestination: SettingsGateDestination.kiosk,
          ),
        ),
        GoRoute(
          path: '/settings/legacy-remotes',
          builder: (_, _) => const SettingsGateScreen(
            initialDestination: SettingsGateDestination.legacyRemote,
          ),
        ),
      ],
    );
    ref.onDispose(router.dispose);
    return router;
  }
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
                    path: 'energy',
                    builder: (_, _) => const EnergyMaintenanceScreen(),
                    routes: [
                      GoRoute(
                        path: 'irrigation-budget',
                        builder: (_, _) => const IrrigationBudgetRoute(),
                      ),
                      GoRoute(
                        path: 'power-budget',
                        builder: (_, _) => const PowerBudgetRoute(),
                      ),
                    ],
                  ),
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
                    path: 'sources',
                    builder: (_, _) => const HaPlaybackScreen(),
                  ),
                  GoRoute(
                    path: 'music',
                    builder: (_, _) => const MusicCenterScreen(),
                  ),
                  GoRoute(
                    path: 'audio',
                    builder: (_, _) => const LocalAudioScreen(),
                  ),
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
      GoRoute(path: '/floor-plan', builder: (_, _) => const FloorPlanRoute()),
      GoRoute(
        path: '/search',
        builder: (context, state) => LocalSearchScreen(
          autofocus: state.uri.queryParameters['focus'] == '1',
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
      GoRoute(
        path: '/settings/kiosk',
        builder: (_, _) => const SettingsGateScreen(
          initialDestination: SettingsGateDestination.kiosk,
        ),
      ),
      GoRoute(
        path: '/settings/tablet-fleet',
        builder: (_, _) => const SettingsGateScreen(
          initialDestination: SettingsGateDestination.tabletFleet,
        ),
      ),
      if (home != null)
        GoRoute(
          path: '/settings/home-source',
          builder: (_, _) => const SettingsGateScreen(
            initialDestination: SettingsGateDestination.homeSource,
          ),
        ),
      GoRoute(
        path: '/settings/client-updates',
        builder: (_, _) => const SettingsGateScreen(
          initialDestination: SettingsGateDestination.clientUpdates,
        ),
      ),
      GoRoute(
        path: '/settings/legacy-remotes',
        builder: (_, _) => const SettingsGateScreen(
          initialDestination: SettingsGateDestination.legacyRemote,
        ),
      ),
      GoRoute(path: '/wellbeing', builder: (_, _) => const WellbeingGate()),
      GoRoute(
        path: '/notifications',
        builder: (_, _) => const LocalNotificationScreen(),
      ),
      if (home != null)
        GoRoute(
          path: '/epaper',
          builder: (_, _) => const EpaperManagementRoute(),
        ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
