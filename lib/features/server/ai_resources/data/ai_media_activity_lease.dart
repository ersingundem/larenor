import 'dart:async';

import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';

/// Short Core lease proving that this Client is actively playing media.
///
/// Renewal failures never interrupt playback. The lease expires by itself, so
/// a killed Client cannot leave local AI permanently throttled.
final class AiMediaActivityLease {
  AiMediaActivityLease(this.account);

  final ServerAccountController account;
  Timer? _timer;
  bool _active = false, _disposed = false;
  int _epoch = 0;

  void setActive(bool value) {
    if (_disposed || value == _active) return;
    _active = value;
    final epoch = ++_epoch;
    _timer?.cancel();
    _timer = null;
    unawaited(_report(value, epoch));
    if (value) {
      _timer = Timer.periodic(
        const Duration(seconds: 45),
        (_) => unawaited(_report(true, epoch)),
      );
    }
  }

  Future<void> _report(
    bool active,
    int epoch, {
    bool allowDisposed = false,
  }) async {
    try {
      await account.withSession((api, session) async {
        if ((!allowDisposed && _disposed) ||
            epoch != _epoch ||
            active != _active) {
          return;
        }
        final context = session.context;
        if (context == null) return;
        await api.request(
          'PUT',
          '/ai-resources/${context.coreId}/${context.homeId}/media-activity',
          token: session.accessToken,
          body: {
            'schemaVersion': 1,
            'active': active,
            'leaseSeconds': active ? 90 : 0,
          },
        );
      });
    } on LarenorServerException {
      // Playback remains authoritative; the bounded lease retries or expires.
    } catch (_) {
      // Network and lifecycle failures are expected during player teardown.
    }
  }

  void dispose() {
    if (_disposed) return;
    final wasActive = _active;
    _active = false;
    _timer?.cancel();
    _timer = null;
    final epoch = ++_epoch;
    if (wasActive) unawaited(_report(false, epoch, allowDisposed: true));
    _disposed = true;
  }
}
