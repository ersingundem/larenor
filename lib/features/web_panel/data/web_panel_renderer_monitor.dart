import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../domain/web_panel_policy.dart';

abstract interface class WebPanelRendererHandle {
  Future<void> dispose();
}

abstract interface class WebPanelRendererMonitor {
  Future<WebPanelRendererHandle?> attach(
    WebViewController controller,
    Set<WebOrigin> allowedOrigins,
    VoidCallback onRendererGone,
  );
}

/// Connects an Android WebView renderer lifetime to one exact Dart controller.
/// The attach call carries only exact origin descriptors, an opaque attachment
/// id and the plugin-owned WebView identifier. Request URLs, paths, headers,
/// cookies and credentials never return over the channel.
final class WebPanelRendererChannel implements WebPanelRendererMonitor {
  WebPanelRendererChannel({
    MethodChannel? channel,
    String Function()? attachmentIds,
  }) : _channel = channel ?? const MethodChannel(channelName),
       _attachmentIds = attachmentIds ?? _secureAttachmentId {
    _channel.setMethodCallHandler(_onMethodCall);
  }

  static const channelName = 'com.ersingundem.larenor/web_panel_renderer';
  static final shared = WebPanelRendererChannel();
  static final _idPattern = RegExp(r'^[0-9a-f]{32}$');

  final MethodChannel _channel;
  final String Function() _attachmentIds;
  final Map<String, VoidCallback> _callbacks = {};

  @override
  Future<WebPanelRendererHandle?> attach(
    WebViewController controller,
    Set<WebOrigin> allowedOrigins,
    VoidCallback onRendererGone,
  ) async {
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    final platform = controller.platform;
    // Test/fallback platform implementations have no native WebView identity.
    if (platform is! AndroidWebViewController) return null;
    return attachIdentifier(
      platform.webViewIdentifier,
      allowedOrigins,
      onRendererGone,
    );
  }

  @visibleForTesting
  Future<WebPanelRendererHandle> attachIdentifier(
    int webViewIdentifier,
    Set<WebOrigin> allowedOrigins,
    VoidCallback onRendererGone,
  ) async {
    final attachmentId = _attachmentIds();
    if (webViewIdentifier < 1 ||
        !_idPattern.hasMatch(attachmentId) ||
        allowedOrigins.isEmpty ||
        allowedOrigins.length > 16) {
      throw StateError('renderer_monitor_invalid');
    }
    if (_callbacks.containsKey(attachmentId)) {
      throw StateError('renderer_monitor_duplicate');
    }
    _callbacks[attachmentId] = onRendererGone;
    try {
      final origins =
          allowedOrigins
              .map(
                (origin) => <String, Object>{
                  'scheme': origin.scheme,
                  'host': origin.host,
                  'port': origin.port,
                },
              )
              .toList(growable: false)
            ..sort((a, b) {
              final scheme = (a['scheme']! as String).compareTo(
                b['scheme']! as String,
              );
              if (scheme != 0) return scheme;
              final host = (a['host']! as String).compareTo(
                b['host']! as String,
              );
              if (host != 0) return host;
              return (a['port']! as int).compareTo(b['port']! as int);
            });
      final attached = await _channel.invokeMethod<bool>('attach', {
        'webViewIdentifier': webViewIdentifier,
        'attachmentId': attachmentId,
        'allowedOrigins': origins,
      });
      if (attached != true) throw StateError('renderer_monitor_unavailable');
      return _ChannelRendererHandle(this, attachmentId);
    } catch (_) {
      _callbacks.remove(attachmentId);
      rethrow;
    }
  }

  Future<void> _onMethodCall(MethodCall call) async {
    if (call.method != 'rendererGone') return;
    final arguments = call.arguments;
    if (arguments is! Map ||
        arguments.length != 1 ||
        arguments['attachmentId'] is! String) {
      return;
    }
    final id = arguments['attachmentId']! as String;
    if (!_idPattern.hasMatch(id)) return;
    final callback = _callbacks.remove(id);
    callback?.call();
  }

  Future<void> _detach(String attachmentId) async {
    if (_callbacks.remove(attachmentId) == null) return;
    try {
      await _channel.invokeMethod<bool>('detach', {
        'attachmentId': attachmentId,
      });
    } on PlatformException {
      // Dart authority was already revoked. Native cleanup is best effort.
    } on MissingPluginException {
      // The engine may already be shutting down.
    }
  }

  static String _secureAttachmentId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }
}

final class _ChannelRendererHandle implements WebPanelRendererHandle {
  _ChannelRendererHandle(this._owner, this._attachmentId);

  WebPanelRendererChannel? _owner;
  final String _attachmentId;

  @override
  Future<void> dispose() async {
    final owner = _owner;
    _owner = null;
    await owner?._detach(_attachmentId);
  }
}
