import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/configuration_writes.dart';
import '../../../core/window/window_policy_models.dart';
import '../../kiosk_remote/runtime/managed_tablet_profile_store.dart';

const windowProfilePreferenceKey = 'window_profile';

abstract interface class WindowProfileStore {
  Future<Object?> read();
  Future<void> write(WindowProfile profile);
}

class PreferenceWindowProfileStore implements WindowProfileStore {
  @override
  Future<Object?> read() async =>
      (await SharedPreferences.getInstance()).get(windowProfilePreferenceKey);

  @override
  Future<void> write(WindowProfile profile) async {
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setString(
      windowProfilePreferenceKey,
      profile.name,
    )) {
      throw StateError('Window profile could not be saved.');
    }
  }
}

final windowProfileStoreProvider = Provider<WindowProfileStore>(
  (_) => PreferenceWindowProfileStore(),
);

final windowProfileProvider =
    AsyncNotifierProvider<WindowProfileNotifier, WindowProfile>(
      WindowProfileNotifier.new,
    );

/// An appearance preference only: it never enrolls or locks the device.
class WindowProfileNotifier extends AsyncNotifier<WindowProfile> {
  bool _managed = false;

  @override
  Future<WindowProfile> build() async {
    final managed = await ref.watch(managedTabletProfileStoreProvider).read();
    if (managed != null) {
      _managed = true;
      return managed.fullscreen ? WindowProfile.panel : WindowProfile.adaptive;
    }
    _managed = false;
    final value = await ref.watch(windowProfileStoreProvider).read();
    return value == WindowProfile.panel.name
        ? WindowProfile.panel
        : WindowProfile.adaptive;
  }

  Future<void> set(WindowProfile profile, {bool Function()? isCurrent}) =>
      ConfigurationWrites.run(() async {
        final current = isCurrent ?? () => true;
        if (!ref.mounted || !current()) return;
        if (_managed) {
          throw StateError('managed_tablet_profile_active');
        }
        await ref.read(windowProfileStoreProvider).write(profile);
        if (ref.mounted && current()) state = AsyncData(profile);
      });
}
