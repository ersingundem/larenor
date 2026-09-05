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
    );

class AmbientSettingsNotifier extends AsyncNotifier<AmbientSettings> {
  @override
  Future<AmbientSettings> build() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.get(AmbientSettings.preferenceKey);
    if (raw == null) return const AmbientSettings();
    if (raw is! String) throw const AmbientException();
    return AmbientSettings.decode(raw);
  }

  Future<void> set(
    AmbientSettings settings, {
    required bool Function() isCurrent,
  }) => ConfigurationWrites.run(() async {
    if (!ref.mounted || !isCurrent()) return;
    final raw = settings.encode();
    AmbientSettings.decode(raw);
    final prefs = await SharedPreferences.getInstance();
    if (!ref.mounted || !isCurrent()) return;
    if (!await prefs.setString(AmbientSettings.preferenceKey, raw)) {
      throw const AmbientException();
    }
    if (ref.mounted) state = AsyncData(settings);
  });
}
