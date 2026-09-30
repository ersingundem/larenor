import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show ChangeNotifierProvider;
import 'package:package_info_plus/package_info_plus.dart';

import '../../../kiosk/data/kiosk_api.dart';
import '../../../kiosk_remote/runtime/managed_tablet_runtime_scope.dart';
import '../../../kiosk_remote/runtime/managed_tablet_profile_store.dart';
import '../../data/server_account_controller.dart';
import '../../providers/server_providers.dart';
import 'android_tablet_fleet_device_platform.dart';
import 'server_tablet_fleet_device_adapter.dart';
import 'tablet_fleet_device_runtime.dart';
import 'tablet_fleet_device_store.dart';

final tabletFleetDeviceStoreProvider = Provider<TabletFleetDeviceStore>(
  (_) => SecureTabletFleetDeviceStore(),
);

final tabletFleetKioskApiProvider = Provider<KioskApi>(
  (_) => AndroidKioskApi(),
);

final tabletFleetClientVersionProvider = Provider<Future<String> Function()>(
  (_) => () async {
    final value = await PackageInfo.fromPlatform();
    final version = value.buildNumber.isEmpty
        ? value.version
        : '${value.version}+${value.buildNumber}';
    if (!RegExp(r'^[0-9A-Za-z.+_-]{1,64}$').hasMatch(version)) {
      throw StateError('invalid_client_version');
    }
    return version;
  },
);

final tabletFleetDeviceRuntimeProvider =
    ChangeNotifierProvider<TabletFleetDeviceRuntime>((ref) {
      final version = ref.watch(tabletFleetClientVersionProvider);
      final random = Random.secure();
      final runtime = TabletFleetDeviceRuntime(
        authority: ServerTabletFleetDeviceAuthority(
          ref.watch(serverAccountControllerProvider),
        ),
        store: ref.watch(tabletFleetDeviceStoreProvider),
        platform: AndroidTabletFleetDevicePlatform(
          kiosk: ref.watch(tabletFleetKioskApiProvider),
          actions: ref.watch(managedTabletLocalActionsProvider),
          profiles: ref.watch(managedTabletProfileStoreProvider),
          activateProfile: ref
              .watch(managedTabletProfileActivationProvider)
              .activate,
          readActiveProfile: () => ref.read(managedTabletActiveProfileProvider),
        ),
        registrationId: () => List.generate(
          16,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join(),
        clientVersion: version,
      );
      return runtime;
    });

/// Keeps an explicitly enrolled tablet alive while the app is foreground.
/// Merely constructing this scope never enrolls a device.
final class TabletFleetDeviceRuntimeScope extends ConsumerStatefulWidget {
  const TabletFleetDeviceRuntimeScope({required this.child, super.key});
  final Widget child;

  @override
  ConsumerState<TabletFleetDeviceRuntimeScope> createState() =>
      _TabletFleetDeviceRuntimeScopeState();
}

final class _TabletFleetDeviceRuntimeScopeState
    extends ConsumerState<TabletFleetDeviceRuntimeScope>
    with WidgetsBindingObserver {
  late final ServerAccountController _account;
  Timer? _timer;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _account = ref.read(serverAccountControllerProvider)
      ..addListener(_authorityChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  void _authorityChanged() => unawaited(_start());

  Future<void> _start() async {
    if (!mounted) return;
    final generation = ++_generation;
    final runtime = ref.read(tabletFleetDeviceRuntimeProvider);
    await runtime.initialize();
    if (!mounted || generation != _generation) return;
    final foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    await runtime.setForeground(foreground);
    if (!mounted || generation != _generation) return;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) unawaited(runtime.synchronize());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    unawaited(
      ref
          .read(tabletFleetDeviceRuntimeProvider)
          .setForeground(state == AppLifecycleState.resumed),
    );
  }

  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    _account.removeListener(_authorityChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
