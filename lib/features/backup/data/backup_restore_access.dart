import '../../../core/home_source_store.dart';

/// An in-process access source. Ownership metadata alone is not authority.
abstract interface class BackupRestoreAccess {
  HomeSource get source;
  Map<String, dynamic> get ownership;
  DateTime get validUntil;
  void checkLive();
  Future<void> checkDurable();
}
