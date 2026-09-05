import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'web_panel_platform.dart';

/// Public plugin operations affect the shared WebView data store. This is not
/// complete per-site logout: the WK API does not clear all IndexedDB data.
class WebPanelDataApi {
  WebViewController? _controller;
  WebViewController get _blank => _controller ??= createWebPanelController();
  Future<void> clearCookies() async {
    await WebViewCookieManager().clearCookies();
  }

  Future<void> clearLocalStorage() => _blank.clearLocalStorage();
  Future<void> clearCache() => _blank.clearCache();
}

/// A global barrier keeps old/late clear completions from reaching a new panel.
/// Failure remains paused until a new explicitly confirmed successful attempt.
class WebPanelDataCoordinator extends ChangeNotifier {
  WebPanelDataCoordinator({WebPanelDataApi? api})
    : _api = api ?? WebPanelDataApi();
  static final shared = WebPanelDataCoordinator();
  final WebPanelDataApi _api;
  final _panels = <Future<void> Function()>{};
  final _retirements = <_Retirement>{};
  bool _blocked = false;
  bool _running = false;
  bool get blocked => _blocked;
  bool get running => _running;

  void register(Future<void> Function() retire) => _panels.add(retire);
  void unregister(Future<void> Function() retire) => _panels.remove(retire);

  /// Also tracks renderers detached before a clear request (route changes,
  /// dispose, idle). Native calls may outlive the Flutter widget.
  void retire(Future<void> Function() operation) {
    final task = _Retirement(operation);
    _retirements.add(task);
    unawaited(
      task.run().then((_) {
        if (task.complete) _retirements.remove(task);
      }),
    );
  }

  Future<bool> clear({required bool Function() isCurrent}) async {
    if (_running || !isCurrent()) return false;
    _running = true;
    _blocked = true;
    // Retire synchronously before any native clearing. Keep futures to await
    // the blanking acknowledgements even though the change listener rebuilds.
    final retired = [
      for (final retire in _panels.toList()) Future<void>.sync(retire),
    ];
    notifyListeners();
    var deadlineExpired = false;
    bool current() => !deadlineExpired && isCurrent();
    Future<bool> operation() async {
      try {
        await Future.wait(retired);
        final tasks = _retirements.toList();
        await Future.wait([for (final task in tasks) task.finish()]);
        _retirements.removeWhere((task) => task.complete);
        if (!current()) return false;
        await _api.clearCookies();
        if (!current()) return false;
        await _api.clearLocalStorage();
        if (!current()) return false;
        await _api.clearCache();
        if (!current()) return false;
        _blocked = false;
        return true;
      } catch (_) {
        return false;
      } finally {
        // An OS operation cannot be cancelled by Dart timeout. Until it really
        // settles no retry or new renderer is permitted.
        _running = false;
        notifyListeners();
      }
    }

    return operation().timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        deadlineExpired = true;
        return false;
      },
    );
  }
}

class _Retirement {
  _Retirement(this.operation);
  final Future<void> Function() operation;
  Future<void>? _pending;
  bool complete = false;
  bool _failed = false;

  Future<void> run() {
    if (complete) return Future.value();
    if (_pending != null) return _pending!;
    final done = Completer<void>();
    _pending = done.future;
    _failed = false;
    Future<void>.sync(operation).then(
      (_) {
        complete = true;
        _pending = null;
        done.complete();
      },
      onError: (Object _, StackTrace _) {
        _failed = true;
        _pending = null;
        done.complete();
      },
    );
    return done.future;
  }

  Future<void> finish() async {
    await run();
    if (_failed) throw StateError('Web panel retirement incomplete');
  }
}
