import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'home_session_controller.dart';
import 'home_source_store.dart';

/// Local source ownership, not PIN, foreground or user-action permission.
/// Production HomeSessionScope supplies an explicit controller. Containers
/// without that scope retain the pre-existing standalone Direct behavior.
final directHomeAccessProvider = Provider.autoDispose<DirectHomeAccess>((ref) {
  final home = ref.watch(homeSessionControllerProvider);
  final identity = home?.runtimeIdentity;
  final access = DirectHomeAccess._(
    () =>
        ref.mounted &&
        (home == null ||
            (home.source == HomeSource.directLocal &&
                !home.busy &&
                home.failure == null &&
                home.usesLocalHome &&
                home.runtimeIdentity == identity)),
  );
  void changed() {
    // Retire synchronously, even if this provider is not rebuilt before a
    // suspended operation resumes or the source later switches back.
    if (!access.isCurrent) access._retire();
    ref.invalidateSelf();
  }

  home?.addListener(changed);
  ref.onDispose(() {
    access._retire();
    home?.removeListener(changed);
  });
  return access;
});

final class DirectHomeAccess {
  DirectHomeAccess._(this._owned);
  final bool Function() _owned;
  bool _retired = false;
  bool get isCurrent {
    if (_retired) return false;
    if (!_owned()) {
      _retired = true;
      return false;
    }
    return true;
  }

  void _retire() => _retired = true;
  void check() {
    if (!isCurrent) throw const DirectHomeAccessException('unavailable');
  }

  /// Recheck each individual platform operation. A dispatched write may have
  /// happened even if its response failed; this never rolls it back or retries.
  Future<T> storage<T>(
    Future<T> Function() operation, {
    bool mutation = false,
  }) async {
    check();
    try {
      final result = await operation();
      check();
      return result;
    } catch (error) {
      if (mutation) throw const DirectHomeAccessException('write_unconfirmed');
      if (error is DirectHomeAccessException) rethrow;
      throw const DirectHomeAccessException('storage_failed');
    }
  }

  @override
  String toString() => 'DirectHomeAccess';
}

final class DirectHomeAccessException implements Exception {
  const DirectHomeAccessException(this.code);
  final String code;
  @override
  String toString() => 'Direct home data is unavailable.';
}
