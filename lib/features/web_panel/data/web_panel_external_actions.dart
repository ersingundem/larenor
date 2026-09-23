import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

enum WebPanelExternalActionKind { email, phone, map }

enum WebPanelExternalActionStatus {
  idle,
  armed,
  awaitingConfirmation,
  working,
  unconfirmed,
  denied,
  failed,
}

@immutable
final class WebPanelExternalAction {
  const WebPanelExternalAction._({
    required this.kind,
    required this.uri,
    required this.display,
  });

  final WebPanelExternalActionKind kind;
  final Uri uri;

  /// Bounded, query-free text suitable for an explicit confirmation surface.
  final String display;

  static WebPanelExternalAction? parse(String raw) {
    if (raw.isEmpty ||
        raw.length > 2048 ||
        raw.contains('%') ||
        raw.contains(RegExp(r'[\x00-\x20\x7f\\?#]'))) {
      return null;
    }
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.authority.isNotEmpty) {
      return null;
    }
    final value = uri.path;
    return switch (uri.scheme.toLowerCase()) {
      'mailto'
          when RegExp(
            r"^[A-Za-z0-9.!#$&'*+/=?^_`{|}~-]{1,64}@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$",
          ).hasMatch(value) =>
        WebPanelExternalAction._(
          kind: WebPanelExternalActionKind.email,
          uri: Uri.parse('mailto:$value'),
          display: value,
        ),
      'tel' when RegExp(r'^\+?[0-9]{3,15}$').hasMatch(value) =>
        WebPanelExternalAction._(
          kind: WebPanelExternalActionKind.phone,
          uri: Uri.parse('tel:$value'),
          display: value,
        ),
      'geo' => _parseMap(value),
      _ => null,
    };
  }

  static WebPanelExternalAction? _parseMap(String value) {
    final match = RegExp(
      r'^(-?(?:[0-9]{1,2}(?:\.[0-9]{1,7})?|90(?:\.0{1,7})?)),(-?(?:[0-9]{1,2}(?:\.[0-9]{1,7})?|1[0-7][0-9](?:\.[0-9]{1,7})?|180(?:\.0{1,7})?))$',
    ).firstMatch(value);
    if (match == null) return null;
    final latitude = double.tryParse(match.group(1)!);
    final longitude = double.tryParse(match.group(2)!);
    if (latitude == null ||
        longitude == null ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      return null;
    }
    return WebPanelExternalAction._(
      kind: WebPanelExternalActionKind.map,
      uri: Uri.parse('geo:$value'),
      display: value,
    );
  }
}

abstract interface class WebPanelExternalActionPort {
  Future<bool> launch(WebPanelExternalAction action);
}

final class LocalWebPanelExternalActionPort
    implements WebPanelExternalActionPort {
  const LocalWebPanelExternalActionPort();

  @override
  Future<bool> launch(WebPanelExternalAction action) =>
      launchUrl(action.uri, mode: LaunchMode.externalApplication);
}

final class WebPanelExternalActionController extends ChangeNotifier {
  WebPanelExternalActionController({
    required this.enabled,
    required this.port,
    required this.isCurrent,
    Duration Function()? elapsed,
  }) : _elapsed = elapsed ?? _newMonotonicClock();

  final bool enabled;
  final WebPanelExternalActionPort port;
  final bool Function() isCurrent;
  final Duration Function() _elapsed;

  WebPanelExternalActionStatus status = WebPanelExternalActionStatus.idle;
  WebPanelExternalAction? pending;
  Duration? _deadline;
  int _epoch = 0;
  bool _disposed = false;

  void arm() {
    if (_disposed || !enabled || !isCurrent()) return;
    _epoch++;
    pending = null;
    _deadline = _elapsed() + const Duration(seconds: 30);
    status = WebPanelExternalActionStatus.armed;
    notifyListeners();
  }

  /// Returns true only when a recognized main-frame external target was
  /// consumed. Unknown schemes remain blocked by the WebPanel navigation policy.
  bool capture(String raw, {required bool mainFrame}) {
    if (_disposed || !enabled || !mainFrame) return false;
    final action = WebPanelExternalAction.parse(raw);
    if (action == null) return false;
    final deadline = _deadline;
    if (!isCurrent() ||
        status != WebPanelExternalActionStatus.armed ||
        deadline == null ||
        _elapsed() >= deadline) {
      _epoch++;
      pending = null;
      _deadline = null;
      status = WebPanelExternalActionStatus.denied;
      notifyListeners();
      return true;
    }
    pending = action;
    status = WebPanelExternalActionStatus.awaitingConfirmation;
    notifyListeners();
    return true;
  }

  Future<void> confirm() async {
    final action = pending;
    final deadline = _deadline;
    if (_disposed ||
        action == null ||
        deadline == null ||
        status != WebPanelExternalActionStatus.awaitingConfirmation) {
      return;
    }
    final epoch = ++_epoch;
    pending = null;
    _deadline = null;
    if (!isCurrent() || _elapsed() >= deadline) {
      status = WebPanelExternalActionStatus.denied;
      notifyListeners();
      return;
    }
    status = WebPanelExternalActionStatus.working;
    notifyListeners();
    try {
      final launched = await port
          .launch(action)
          .timeout(const Duration(seconds: 5));
      if (_disposed || epoch != _epoch || !isCurrent()) return;
      status = launched
          ? WebPanelExternalActionStatus.unconfirmed
          : WebPanelExternalActionStatus.failed;
      notifyListeners();
    } catch (_) {
      if (_disposed || epoch != _epoch || !isCurrent()) return;
      status = WebPanelExternalActionStatus.failed;
      notifyListeners();
    }
  }

  static Duration Function() _newMonotonicClock() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }

  void cancel() => retire();

  void retire() {
    if (_disposed) return;
    _epoch++;
    pending = null;
    _deadline = null;
    status = WebPanelExternalActionStatus.idle;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _epoch++;
    pending = null;
    _deadline = null;
    status = WebPanelExternalActionStatus.idle;
    super.dispose();
  }
}
