import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/configuration_writes.dart';
import '../data/screen_program_store.dart';
import '../domain/screen_program.dart';
import 'settings_providers.dart';

final screenProgramStoreProvider = Provider<ScreenProgramStore>(
  (ref) => PreferenceScreenProgramStore(),
);
final screenProgramProvider =
    AsyncNotifierProvider<ScreenProgramNotifier, ScreenProgram>(
      ScreenProgramNotifier.new,
      retry: (_, _) => null,
    );

class ScreenProgramNotifier extends AsyncNotifier<ScreenProgram> {
  @override
  Future<ScreenProgram> build() async {
    // Preserve a live legacy source until the first explicit weekly save.
    final nightFuture = ref.watch(nightWindowProvider.future);
    final raw = await ref.watch(screenProgramStoreProvider).read();
    if (raw != null) return ScreenProgram.decode(raw);
    final night = await nightFuture;
    final migrated = ScreenProgram.legacy(
      startMinutes: night.startMinutes,
      endMinutes: night.endMinutes,
      dim: night.dimBrightnessAtNight,
      systemTimeout: night.screenOffAtNight,
    );
    return ScreenProgram.fromJson(migrated.toJson());
  }

  Future<void> save(
    ScreenProgram value, {
    required bool Function() isCurrent,
  }) => ConfigurationWrites.run(() async {
    if (!ref.mounted || !isCurrent()) {
      throw StateError('Screen program session expired');
    }
    final raw = value.encode();
    if (!isCurrent()) throw StateError('Screen program session expired');
    await ref.read(screenProgramStoreProvider).write(raw);
    if (ref.mounted) state = AsyncData(ScreenProgram.decode(raw));
  });
}
