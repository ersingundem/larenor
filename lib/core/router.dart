import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/presentation/connect_screen.dart';
import '../features/auth/providers/auth_providers.dart';
import '../features/dashboard/presentation/home_dashboard_screen.dart';
import '../features/media/hub/presentation/media_hub_screen.dart';
import '../features/settings/presentation/settings_gate_screen.dart';
import '../l10n/generated/app_localizations.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (context, state) => const _RootScreen()),
      GoRoute(
        path: '/media',
        builder: (context, state) => const MediaHubScreen(),
      ),
      GoRoute(
        path: '/settings',
        builder: (context, state) => const SettingsGateScreen(),
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});

/// Shows the connect flow or the dashboard depending on whether the app
/// already has a saved Home Assistant connection.
class _RootScreen extends ConsumerWidget {
  const _RootScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configAsync = ref.watch(connectionConfigProvider);
    return configAsync.when(
      loading: () => const CupertinoPageScaffold(
        child: Center(child: CupertinoActivityIndicator()),
      ),
      error: (error, _) => CupertinoPageScaffold(
        child: Center(
          child: Text(
            AppLocalizations.of(context).rootScreenError(error.toString()),
          ),
        ),
      ),
      data: (config) =>
          config == null ? const ConnectScreen() : const HomeDashboardScreen(),
    );
  }
}
