import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  Future<WellbeingSettings> build() => ref.watch(wellbeingStoreProvider).read();
  Future<void> save(
    WellbeingSettings value, {
    required bool Function() isCurrent,
  }) async {
    await ref
        .read(wellbeingStoreProvider)
        .save(value, isCurrent: () => ref.mounted && isCurrent());
    if (ref.mounted) state = AsyncData(value);
  }

  Future<void> clear({required bool Function() isCurrent}) async {
    await ref
        .read(wellbeingStoreProvider)
        .clear(isCurrent: () => ref.mounted && isCurrent());
    if (ref.mounted) state = AsyncData(WellbeingSettings());
  }
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
