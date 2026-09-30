import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../server/data/server_account_controller.dart';
import '../../server/providers/server_providers.dart';
import '../../dashboard/providers/dashboard_providers.dart';
import '../../settings/providers/settings_providers.dart';
import '../../settings/providers/window_profile_provider.dart';
import 'managed_tablet_credential_store.dart';
import 'managed_tablet_mqtt_settings.dart';
import 'managed_tablet_mqtt_runtime.dart';
import 'managed_tablet_profile_store.dart';
import 'managed_tablet_profile_sync.dart';
import 'managed_tablet_runtime_owner.dart';
import 'mqtt_local_broker.dart';
import 'native_managed_tablet_source.dart';

final managedTabletMqttSettingsStoreProvider =
    Provider<ManagedTabletMqttSettingsStore>(
      (_) => SharedPreferencesManagedTabletMqttSettingsStore(),
    );

final managedTabletMqttSettingsRepositoryProvider =
    Provider<ManagedTabletMqttSettingsRepository>(
      (ref) => ManagedTabletMqttSettingsRepository(
        ref.watch(managedTabletMqttSettingsStoreProvider),
      ),
    );

final managedTabletMqttSettingsProvider =
    AsyncNotifierProvider<
      ManagedTabletMqttSettingsController,
      LocalMqttBrokerSettings
    >(ManagedTabletMqttSettingsController.new);

final class ManagedTabletMqttSettingsController
    extends AsyncNotifier<LocalMqttBrokerSettings> {
  @override
  Future<LocalMqttBrokerSettings> build() =>
      ref.watch(managedTabletMqttSettingsRepositoryProvider).read();

  Future<void> save(
    LocalMqttBrokerSettings settings, {
    required bool Function() isCurrent,
  }) async {
    await ref
        .read(managedTabletMqttSettingsRepositoryProvider)
        .save(
          settings,
          isCurrent: isCurrent,
          publish: (saved) {
            if (!isCurrent()) {
              throw StateError('mqtt_settings_write_retired');
            }
            state = AsyncData(saved);
          },
        );
  }
}

final managedTabletDefaultMqttSettingsProvider =
    Provider<LocalMqttBrokerSettings>(
      (_) => LocalMqttBrokerSettings.disabled(),
    );

final managedTabletCredentialStoreProvider =
    Provider<ManagedTabletCredentialStore>(
      (_) => SecureManagedTabletCredentialStore(),
    );

final managedTabletCoreAuthorityProvider = Provider<ManagedTabletCoreAuthority>(
  (_) => CoreManagedTabletAuthority(),
);

final managedTabletProfileActivationProvider =
    Provider<ManagedTabletProfileActivation>((ref) {
      return ManagedTabletProfileActivation(
        current: () => ref.mounted,
        publish: (authority, profile) => ref
            .read(managedTabletActiveProfileProvider.notifier)
            .activateForAuthority(authority, profile),
        refresh: () async {
          if (!ref.mounted) {
            throw StateError('managed_tablet_action_retired');
          }
          ref.invalidate(windowProfileProvider);
          ref.invalidate(idleModeProvider);
          await Future.wait([
            ref.read(windowProfileProvider.future),
            ref.read(idleModeProvider.future),
          ]);
        },
      );
    });

/// Publishes one verified profile authority and refreshes the settings that
/// consume it. Clearing is exact: a retired K07 enrollment cannot erase an F53
/// fleet profile that became active while its callback was in flight.
final class ManagedTabletProfileActivation {
  const ManagedTabletProfileActivation({
    required this.current,
    required this.publish,
    required this.refresh,
  });

  final bool Function() current;
  final bool Function(
    ManagedTabletProfileAuthority authority,
    AppliedManagedTabletProfile? profile,
  )
  publish;
  final Future<void> Function() refresh;

  Future<void> activate(
    ManagedTabletProfileAuthority authority,
    AppliedManagedTabletProfile? profile,
  ) async {
    if (!current()) throw StateError('managed_tablet_action_retired');
    final changed = publish(authority, profile);
    if (profile == null && !changed) return;
    await refresh();
    if (!current()) throw StateError('managed_tablet_action_retired');
  }
}

final managedTabletProfileSynchronizerProvider =
    Provider<ManagedTabletProfileSynchronizer>(
      (ref) => ManagedTabletProfileSynchronizer(
        account: ref.watch(serverAccountControllerProvider),
        credentials: ref.watch(managedTabletCredentialStoreProvider),
        profiles: ref.watch(managedTabletProfileStoreProvider),
        activate: ref.watch(managedTabletProfileActivationProvider).activate,
      ),
    );

final managedTabletLocalActionsProvider = Provider<ManagedTabletLocalActions>(
  (ref) => CallbackManagedTabletLocalActions(
    onRefreshDashboard: (isCurrent) async {
      if (!ref.mounted || !isCurrent()) {
        throw StateError('managed_tablet_action_retired');
      }
      ref.invalidate(dashboardLayoutProvider);
      await ref.read(dashboardLayoutProvider.future);
      if (!ref.mounted || !isCurrent()) {
        throw StateError('managed_tablet_action_retired');
      }
    },
    onSyncProfile: (clientVersion, isCurrent) => ref
        .read(managedTabletProfileSynchronizerProvider)
        .synchronize(clientVersion: clientVersion, isCurrent: isCurrent),
  ),
);

final managedTabletRuntimeOwnerProvider =
    Provider.autoDispose<ManagedTabletRuntimeOwner>((ref) {
      final owner = ManagedTabletRuntimeOwner(
        store: ref.watch(managedTabletCredentialStoreProvider),
        authority: ref.watch(managedTabletCoreAuthorityProvider),
        source: NativeManagedTabletSource(
          // The source is still gated by verified enrollment, foreground and
          // enabled TLS settings in the owner before a native lease is asked.
          config: const NativeManagedTabletSourceConfig(enabled: true),
          actions: ref.watch(managedTabletLocalActionsProvider),
        ),
        broker: MqttClientLocalBroker(),
        settings: ref.watch(managedTabletDefaultMqttSettingsProvider),
        stateStore: SharedPreferencesManagedMqttStateStore(),
        now: DateTime.now,
        onAuthorityRetired: (enrollment) async {
          if (!ref.mounted) return;
          await ref
              .read(managedTabletProfileActivationProvider)
              .activate(
                ManagedTabletProfileAuthority.fromEnrollment(enrollment),
                null,
              );
        },
      );
      ref.onDispose(() => unawaited(owner.dispose()));
      return owner;
    });

/// Binds the runtime owner to the verified account/Core and application
/// foreground. The parent home runtime is also replaced on home-source changes,
/// which disposes this owner before the replacement container is mounted.
final class ManagedTabletRuntimeScope extends ConsumerStatefulWidget {
  const ManagedTabletRuntimeScope({required this.child, super.key});
  final Widget child;

  @override
  ConsumerState<ManagedTabletRuntimeScope> createState() =>
      _ManagedTabletRuntimeScopeState();
}

final class _ManagedTabletRuntimeScopeState
    extends ConsumerState<ManagedTabletRuntimeScope>
    with WidgetsBindingObserver {
  late final ServerAccountController _account;
  late final ManagedTabletActiveProfileController _activeProfile;
  LocalMqttBrokerSettings? _appliedSettings;
  ManagedTabletRuntimeOwner? _appliedOwner;
  ManagedTabletProfileAuthority? _profileAuthority;
  int _profileAuthorityGeneration = 0;

  @override
  void initState() {
    super.initState();
    _activeProfile = ref.read(managedTabletActiveProfileProvider.notifier);
    _account = ref.read(serverAccountControllerProvider)
      ..addListener(_synchronize);
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    final foreground = state == null || state == AppLifecycleState.resumed;
    unawaited(
      ref.read(managedTabletRuntimeOwnerProvider).setForeground(foreground),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _synchronize());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    unawaited(
      ref
          .read(managedTabletRuntimeOwnerProvider)
          .setForeground(state == AppLifecycleState.resumed),
    );
  }

  ManagedTabletBinding? _currentBinding() {
    final session = _account.session;
    final context = session?.context;
    if (session == null || context == null || session.user.mustChangePassword) {
      return null;
    }
    return ManagedTabletBinding(
      serverBaseUrl: session.endpoint.baseUrl,
      coreId: context.coreId,
      homeId: context.homeId,
      accountId: session.user.id,
    );
  }

  void _synchronize() {
    if (!mounted) return;
    final generation = ++_profileAuthorityGeneration;
    final binding = _currentBinding();
    unawaited(_synchronizeAuthority(generation, binding).catchError((_) {}));
  }

  Future<void> _synchronizeAuthority(
    int generation,
    ManagedTabletBinding? binding,
  ) async {
    await ref.read(managedTabletRuntimeOwnerProvider).updateBinding(binding);
    if (!_authorityCurrent(generation, binding)) return;
    if (binding == null) {
      await _clearKnownProfile(generation, binding);
      return;
    }
    try {
      final enrollment = await ref
          .read(managedTabletCredentialStoreProvider)
          .read();
      if (!_authorityCurrent(generation, binding) ||
          enrollment?.binding != binding ||
          !enrollment!.expiresAt.isAfter(DateTime.now().toUtc())) {
        await _clearKnownProfile(generation, binding);
        return;
      }
      final authority = ManagedTabletProfileAuthority.fromEnrollment(
        enrollment,
      );
      final previous = _profileAuthority;
      _profileAuthority = authority;
      if (previous != null && previous.fingerprint != authority.fingerprint) {
        await ref
            .read(managedTabletProfileActivationProvider)
            .activate(previous, null);
      }
      final profile = await ref
          .read(managedTabletProfileStoreProvider)
          .readFor(enrollment);
      if (!_authorityCurrent(generation, binding)) {
        return;
      }
      await ref
          .read(managedTabletProfileActivationProvider)
          .activate(authority, profile);
    } catch (_) {
      if (_authorityCurrent(generation, binding)) {
        await _clearKnownProfile(generation, binding);
      }
    }
  }

  Future<void> _clearKnownProfile(
    int generation,
    ManagedTabletBinding? binding,
  ) async {
    final authority = _profileAuthority;
    _profileAuthority = null;
    if (authority == null || !_authorityCurrent(generation, binding)) return;
    await ref
        .read(managedTabletProfileActivationProvider)
        .activate(authority, null);
  }

  bool _authorityCurrent(int generation, ManagedTabletBinding? binding) =>
      mounted &&
      generation == _profileAuthorityGeneration &&
      _currentBinding() == binding;

  @override
  void dispose() {
    _profileAuthorityGeneration++;
    WidgetsBinding.instance.removeObserver(this);
    _account.removeListener(_synchronize);
    // Riverpod forbids provider mutations while Flutter is unmounting this
    // widget. Retire after the lifecycle callback, and tolerate a parent
    // ProviderScope being disposed in the same turn.
    final authority = _profileAuthority;
    if (authority != null) {
      Future<void>.microtask(
        () => _activeProfile.clearIfMountedForAuthority(authority),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final owner = ref.watch(managedTabletRuntimeOwnerProvider);
    final settings = ref.watch(managedTabletMqttSettingsProvider).value;
    if (settings != null &&
        (settings != _appliedSettings || !identical(owner, _appliedOwner))) {
      _appliedSettings = settings;
      _appliedOwner = owner;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _appliedSettings == settings &&
            identical(_appliedOwner, owner)) {
          unawaited(owner.updateSettings(settings));
        }
      });
    }
    return widget.child;
  }
}
