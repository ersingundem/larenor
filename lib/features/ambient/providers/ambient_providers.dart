import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/configuration_writes.dart';
import '../data/ambient_repository.dart';
import '../domain/ambient_settings.dart';

final ambientRepositoryProvider = Provider((_) => AmbientRepository());
final ambientFileAccessProvider = Provider((_) => AmbientFileAccess());
final ambientLibraryProvider = FutureProvider<List<String>>(
  (ref) => ref.watch(ambientRepositoryProvider).list(),
);
final ambientPhotoProvider = FutureProvider.autoDispose
    .family<Uint8List, String>(
      (ref, id) => ref.watch(ambientRepositoryProvider).readPhoto(id),
    );
final ambientSettingsProvider =
    AsyncNotifierProvider<AmbientSettingsNotifier, AmbientSettings>(
      AmbientSettingsNotifier.new,
      retry: (_, _) => null,
    );

class AmbientSettingsNotifier extends AsyncNotifier<AmbientSettings> {
  @override
  Future<AmbientSettings> build() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Legacy SharedPreferences updates its cache before platform success.
      // A failed opt-in must never become confirmed through that cache.
      await prefs.reload();
      final raw = prefs.get(AmbientSettings.preferenceKey);
      if (raw == null) return const AmbientSettings();
      if (raw is! String) throw const AmbientException();
      return AmbientSettings.decode(raw);
    } catch (_) {
      throw const AmbientException();
    }
  }

  bool _current(bool Function() isCurrent) {
    try {
      return ref.mounted && isCurrent();
    } catch (_) {
      throw const AmbientException();
    }
  }

  Future<void> set(
    AmbientSettings settings, {
    required bool Function() isCurrent,
  }) => ConfigurationWrites.run(() async {
    if (!_current(isCurrent)) return;
    final raw = settings.encode();
    AmbientSettings.decode(raw);
    state = const AsyncLoading();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!_current(isCurrent)) throw const AmbientException();
      if (!await prefs.setString(AmbientSettings.preferenceKey, raw)) {
        throw const AmbientException();
      }
      if (!_current(isCurrent)) throw const AmbientException();
      state = AsyncData(settings);
    } catch (_) {
      if (ref.mounted) {
        state = AsyncError(const AmbientException(), StackTrace.empty);
      }
      throw const AmbientException();
    }
  });
}
