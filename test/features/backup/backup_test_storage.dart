import 'package:larenor/features/backup/data/backup_storage.dart';

class MemoryBackupStorage implements BackupStorage {
  MemoryBackupStorage({
    Map<String, Object?>? preferences,
    Map<String, String>? secrets,
  }) : preferences = {...?preferences},
       secrets = {...?secrets};
  final Map<String, Object?> preferences;
  final Map<String, String> secrets;
  final List<String> reads = [];
  final List<String> writes = [];
  final Set<int> failWrites = {};
  final List<MemoryBackupStorage> durableImages = [];
  int writeCount = 0;
  bool failReads = false;

  @override
  Future<Object?> readPreference(String key) async {
    reads.add('pref:$key');
    if (failReads) throw StateError('Synthetic storage error');
    return preferences[key];
  }

  @override
  Future<String?> readSecret(String key) async {
    reads.add('secret:$key');
    if (failReads) throw StateError('Synthetic storage error');
    return secrets[key];
  }

  @override
  Future<void> writePreference(String key, Object? value) async {
    _beforeWrite('pref:$key');
    if (value == null) {
      preferences.remove(key);
    } else {
      preferences[key] = value;
    }
    _afterWrite();
  }

  @override
  Future<void> writeSecret(String key, String? value) async {
    _beforeWrite('secret:$key');
    if (value == null) {
      secrets.remove(key);
    } else {
      secrets[key] = value;
    }
    _afterWrite();
  }

  void _beforeWrite(String name) {
    writes.add(name);
    writeCount++;
    if (failWrites.contains(writeCount)) {
      throw StateError('Synthetic storage error');
    }
  }

  void _afterWrite() {
    durableImages.add(
      MemoryBackupStorage(preferences: preferences, secrets: secrets),
    );
  }
}
