import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/configuration_writes.dart';
import '../../auth/providers/auth_providers.dart';
import '../../ha_client/providers/ha_client_providers.dart';
import '../../health/data/health_configuration.dart';
import '../data/ha_wellbeing_api.dart';
import '../data/wellbeing_controller.dart';
import '../data/wellbeing_native_api.dart';
import '../data/wellbeing_store.dart';
import '../data/wellbeing_disclosure_policy.dart';
import '../domain/wellbeing_models.dart';

final wellbeingStoreProvider = Provider<WellbeingStore>(
  (ref) => WellbeingStore(),
);
final wellbeingSettingsProvider =
    AsyncNotifierProvider<WellbeingSettingsNotifier, WellbeingSettings>(
      WellbeingSettingsNotifier.new,
      retry: (_, _) => null,
    );

class WellbeingSettingsNotifier extends AsyncNotifier<WellbeingSettings> {
  @override
  Future<WellbeingSettings> build() {
    final store = ref.watch(wellbeingStoreProvider);
    // Invalidation cannot confirm old privacy while a dispatched write is
    // unresolved. Keep the filter loading until the serialized fresh read.
    return ConfigurationWrites.run(store.read);
  }

  Future<void> _mutate(
    WellbeingSettings value,
    Future<void> Function(Ref, bool Function()) write,
    bool Function() isCurrent,
  ) {
    final captured = ref;
    return ConfigurationWrites.run(() async {
      bool current() => captured.mounted && isCurrent();
      // A stale invocation must not disturb a newer confirmed state.
      requireCurrentWellbeingAction(current);
      state = const AsyncLoading();
      try {
        await write(captured, current);
        requireCurrentWellbeingAction(current);
        state = AsyncData(value);
      } catch (error) {
        final failure = error is WellbeingException
            ? error
            : const WellbeingException(WellbeingFailure.storageFailed);
        // The write may already have taken effect. Only an explicit local reread
        // can confirm the stored privacy policy; do not retry or roll it back.
        if (captured.mounted) state = AsyncError(failure, StackTrace.empty);
        throw failure;
      }
    });
  }

  Future<void> save(
    WellbeingSettings value, {
    required bool Function() isCurrent,
  }) => _mutate(
    value,
    (captured, current) =>
        captured.read(wellbeingStoreProvider).save(value, isCurrent: current),
    isCurrent,
  );

  Future<void> clear({required bool Function() isCurrent}) => _mutate(
    WellbeingSettings(),
    (captured, current) =>
        captured.read(wellbeingStoreProvider).clear(isCurrent: current),
    isCurrent,
  );
}

/// Callers must treat loading/error as an unavailable privacy filter. Bindings
/// remain private even while opted out, until explicitly removed locally.
final wellbeingPrivateEntityIdsProvider = Provider<AsyncValue<Set<String>>>((
  ref,
) {
  final settings = ref.watch(wellbeingSettingsProvider);
  final disclosure = ref.watch(wellbeingDisclosureProvider);
  if (settings.isLoading || disclosure.isLoading) return const AsyncLoading();
  if (settings.hasError || disclosure.hasError) {
    return AsyncError(
      const WellbeingException(WellbeingFailure.storageFailed),
      StackTrace.empty,
    );
  }
  if (disclosure.requireValue.reviewRequired) {
    return AsyncError(
      const WellbeingException(WellbeingFailure.locked),
      StackTrace.empty,
    );
  }
  return AsyncData(
    Set.unmodifiable({
      ...settings.requireValue.bindings.map((v) => v.entityId),
      ...disclosure.requireValue.entityIds,
    }),
  );
});

final wellbeingAccessProvider = Provider<WellbeingAccessSession?>(
  (ref) => null,
);
final wellbeingNativeApiProvider = Provider<WellbeingNativeApi>(
  (ref) => ChannelWellbeingNativeApi(),
);
final haWellbeingApiProvider = Provider.autoDispose<HaWellbeingApi?>((ref) {
  final access = ref.watch(wellbeingAccessProvider);
  if (access == null || !access.isCurrent()) return null;
  final config = ref.watch(connectionConfigProvider);
  if (config.isLoading || config.hasError || config.value == null) return null;
  final captured = config.value!;
  final client = ref.watch(haRestClientProvider);
  if (client == null) return null;
  return RestHaWellbeingApi(
    client: client,
    accountFingerprint: wellbeingAccountFingerprint(captured),
    isCurrent: () {
      if (!ref.mounted || !access.isCurrent()) return false;
      final latest = ref.read(connectionConfigProvider);
      return !latest.isLoading &&
          !latest.hasError &&
          sameHealthConfiguration(captured, latest.value);
    },
  );
}, dependencies: [wellbeingAccessProvider]);

final wellbeingControllerProvider = Provider.autoDispose<WellbeingController?>((
  ref,
) {
  final access = ref.watch(wellbeingAccessProvider);
  if (access == null || !access.isCurrent()) return null;
  final settings = ref.watch(wellbeingSettingsProvider);
  if (settings.isLoading || settings.hasError || settings.value == null) {
    return null;
  }
  final controller = WellbeingController(
    nativeApi: ref.watch(wellbeingNativeApiProvider),
    haApi: ref.watch(haWellbeingApiProvider),
    settings: settings.value!,
    accessCurrent: () => ref.mounted && access.isCurrent(),
  );
  final lifecycle = AppLifecycleListener(
    onStateChange: (state) =>
        controller.setForeground(state == AppLifecycleState.resumed),
  );
  final initial = WidgetsBinding.instance.lifecycleState;
  controller.setForeground(
    initial == null || initial == AppLifecycleState.resumed,
  );
  ref.onDispose(() {
    lifecycle.dispose();
    controller.dispose();
  });
  return controller;
}, dependencies: [wellbeingAccessProvider, haWellbeingApiProvider]);

final wellbeingProvider = StreamProvider.autoDispose<WellbeingSnapshot>(
  (ref) =>
      ref.watch(wellbeingControllerProvider)?.stream ??
      Stream.value(WellbeingSnapshot()),
  retry: (_, _) => null,
  dependencies: [wellbeingControllerProvider],
);
