import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/presentation/connect_screen.dart';
import '../features/auth/providers/auth_providers.dart';
import '../features/dashboard/presentation/dashboard_screen.dart';
import '../features/settings/presentation/settings_gate_screen.dart';

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (context, state) => const _RootScreen()),
      GoRoute(
        path: '/settings',
        builder: (context, state) => const SettingsGateScreen(),
      ),
    ],
  );
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
        child: Center(child: Text('Something went wrong: $error')),
      ),
      data: (config) =>
          config == null ? const ConnectScreen() : const DashboardScreen(),
    );
  }
}
