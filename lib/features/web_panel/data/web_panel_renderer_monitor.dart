import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../domain/web_panel_policy.dart';
import '../domain/web_panel_native_bridge.dart';

@immutable
final class WebPanelNativeMessage {
  const WebPanelNativeMessage({
    required this.message,
    required this.topOrigin,
    required this.policyRevision,
  });

  final String message, topOrigin;
  final int policyRevision;
}

typedef WebPanelNativeMessageHandler = Future<String> Function(
  WebPanelNativeMessage message,
);

abstract interface class WebPanelRendererHandle {
  Future<void> dispose();
}

abstract interface class WebPanelRendererMonitor {
  Future<WebPanelRendererHandle?> attach(
    WebViewController controller,
    Set<WebOrigin> allowedOrigins,
    VoidCallback onRendererGone, {
    WebPanelNativePolicy? nativePolicy,
    WebPanelNativeMessageHandler? onNativeMessage,
  });
}

/// Connects an Android WebView renderer lifetime to one exact Dart controller.
/// The attach call carries only exact origin descriptors, an opaque attachment
/// id and the plugin-owned WebView identifier. Request URLs, paths, headers,
/// cookies and credentials never return over the channel.
final class WebPanelRendererChannel implements WebPanelRendererMonitor {
  WebPanelRendererChannel({
    MethodChannel? channel,
    String Function()? attachmentIds,
    this.operationTimeout = const Duration(seconds: 4),
  }) : _channel = channel ?? const MethodChannel(channelName),
       _attachmentIds = attachmentIds ?? _secureAttachmentId {
    _channel.setMethodCallHandler(_onMethodCall);
  }

  static const channelName = 'com.ersingundem.larenor/web_panel_renderer';
  static final shared = WebPanelRendererChannel();
  static final _idPattern = RegExp(r'^[0-9a-f]{32}$');

  final MethodChannel _channel;
  final String Function() _attachmentIds;
  final Duration operationTimeout;
  final Map<String, _AttachmentCallbacks> _callbacks = {};
  final Set<String> _pendingLateAcknowledgements = {};

  @override
  Future<WebPanelRendererHandle?> attach(
    WebViewController controller,
    Set<WebOrigin> allowedOrigins,
    VoidCallback onRendererGone, {
    WebPanelNativePolicy? nativePolicy,
    WebPanelNativeMessageHandler? onNativeMessage,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    final platform = controller.platform;
    // Test/fallback platform implementations have no native WebView identity.
    if (platform is! AndroidWebViewController) return null;
    return attachIdentifier(
      platform.webViewIdentifier,
      allowedOrigins,
      onRendererGone,
      nativePolicy: nativePolicy,
      onNativeMessage: onNativeMessage,
    );
  }

  @visibleForTesting
  Future<WebPanelRendererHandle> attachIdentifier(
    int webViewIdentifier,
    Set<WebOrigin> allowedOrigins,
    VoidCallback onRendererGone, {
    WebPanelNativePolicy? nativePolicy,
    WebPanelNativeMessageHandler? onNativeMessage,
  }) async {
    final attachmentId = _attachmentIds();
    if (webViewIdentifier < 1 ||
        operationTimeout <= Duration.zero ||
        !_idPattern.hasMatch(attachmentId) ||
        allowedOrigins.isEmpty ||
        allowedOrigins.length > 16) {
      throw StateError('renderer_monitor_invalid');
    }
    if ((nativePolicy == null) != (onNativeMessage == null) ||
        (nativePolicy != null && !nativePolicy.valid)) {
      throw StateError('renderer_monitor_invalid');
    }
    if (_callbacks.containsKey(attachmentId) ||
        _pendingLateAcknowledgements.contains(attachmentId)) {
      throw StateError('renderer_monitor_duplicate');
    }
    _callbacks[attachmentId] = _AttachmentCallbacks(
      onRendererGone,
      nativePolicy,
      onNativeMessage,
    );
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
      final invocation = _channel.invokeMethod<bool>('attach', {
        'webViewIdentifier': webViewIdentifier,
        'attachmentId': attachmentId,
        'allowedOrigins': origins,
        if (nativePolicy != null) 'nativePolicy': nativePolicy.toJson(),
      });
      bool? attached;
      try {
        attached = await invocation.timeout(operationTimeout);
      } on TimeoutException {
        _callbacks.remove(attachmentId);
        _pendingLateAcknowledgements.add(attachmentId);
        unawaited(
          _detachLateAcknowledgement(invocation, attachmentId).whenComplete(
            () => _pendingLateAcknowledgements.remove(attachmentId),
          ),
        );
        throw StateError('renderer_monitor_timeout');
      }
      if (attached != true) throw StateError('renderer_monitor_unavailable');
      return _ChannelRendererHandle(this, attachmentId);
    } catch (_) {
      _callbacks.remove(attachmentId);
      rethrow;
    }
  }

  Future<void> _onMethodCall(MethodCall call) async {
    if (call.method == 'nativeMessage') {
      await _onNativeMessage(call.arguments);
      return;
    }
    if (call.method != 'rendererGone') return;
    final arguments = call.arguments;
    if (arguments is! Map ||
        arguments.length != 1 ||
        arguments['attachmentId'] is! String) {
      return;
    }
    final id = arguments['attachmentId']! as String;
    if (!_idPattern.hasMatch(id)) return;
    final callback = _callbacks.remove(id)?.rendererGone;
    try {
      callback?.call();
    } catch (_) {
      // A retired UI callback never becomes a platform-channel failure.
    }
  }

  Future<void> _onNativeMessage(Object? arguments) async {
    if (arguments is! Map ||
        arguments.keys.toSet().length != 5 ||
        !arguments.keys.toSet().containsAll(const {
          'attachmentId',
          'messageId',
          'message',
          'topOrigin',
          'policyRevision',
        })) {
      return;
    }
    final id = arguments['attachmentId'];
    final messageId = arguments['messageId'];
    final message = arguments['message'];
    final topOrigin = arguments['topOrigin'];
    final revision = arguments['policyRevision'];
    if (id is! String ||
        !_idPattern.hasMatch(id) ||
        messageId is! int ||
        messageId < 1 ||
        message is! String ||
        topOrigin is! String ||
        revision is! int) {
      return;
    }
    final binding = _callbacks[id];
    final policy = binding?.nativePolicy;
    final handler = binding?.nativeMessage;
    if (binding == null ||
        policy == null ||
        handler == null ||
        policy.revision != revision ||
        policy.topOrigin != topOrigin) {
      return;
    }
    String reply;
    try {
      reply = await handler(
        WebPanelNativeMessage(
          message: message,
          topOrigin: topOrigin,
          policyRevision: revision,
        ),
      );
    } catch (_) {
      reply = '{"schemaVersion":1,"status":"denied","reasonCode":"authority_denied"}';
    }
    if (!identical(_callbacks[id], binding)) return;
    try {
      await _channel
          .invokeMethod<bool>('replyNative', {
            'attachmentId': id,
            'messageId': messageId,
            'message': reply,
          })
          .timeout(operationTimeout);
    } on TimeoutException {
      // The authority remains revoked locally; native drops late reply ids.
    } on PlatformException {
      // Native attachment was retired or rejected the bounded reply.
    } on MissingPluginException {
      // The engine may already be shutting down.
    }
  }

  Future<void> _detach(String attachmentId) async {
    if (_callbacks.remove(attachmentId) == null) return;
    await _invokeDetach(attachmentId);
  }

  Future<void> _detachLateAcknowledgement(
    Future<bool?> invocation,
    String attachmentId,
  ) async {
    try {
      if (await invocation == true) await _invokeDetach(attachmentId);
    } catch (_) {
      // A late rejected/failed attachment has no native authority to revoke.
    }
  }

  Future<void> _invokeDetach(String attachmentId) async {
    try {
      await _channel
          .invokeMethod<bool>('detach', {'attachmentId': attachmentId})
          .timeout(operationTimeout);
    } on TimeoutException {
      // Dart authority is already revoked; native owns its final cleanup.
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

final class _AttachmentCallbacks {
  const _AttachmentCallbacks(
    this.rendererGone,
    this.nativePolicy,
    this.nativeMessage,
  );

  final VoidCallback rendererGone;
  final WebPanelNativePolicy? nativePolicy;
  final WebPanelNativeMessageHandler? nativeMessage;
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
