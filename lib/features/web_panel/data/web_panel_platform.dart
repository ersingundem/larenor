import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../domain/web_panel_options.dart';

Future<void> configureWebPanelAppearance(
  WebViewController controller,
  WebPanelOptions? options,
  Future<void> Function(Future<void> Function()) step,
) async {
  await step(() => controller.enableZoom(options?.zoomEnabled ?? true));
  final platform = controller.platform;
  if (platform is AndroidWebViewController) {
    await step(() => platform.setTextZoom(options?.textZoom ?? 100));
  }
}

WebViewController createWebPanelController() {
  PlatformWebViewControllerCreationParams params =
      const PlatformWebViewControllerCreationParams();
  if (WebViewPlatform.instance is WebKitWebViewPlatform) {
    params = WebKitWebViewControllerCreationParams(
      mediaTypesRequiringUserAction: {
        PlaybackMediaTypes.audio,
        PlaybackMediaTypes.video,
      },
      javaScriptCanOpenWindowsAutomatically: false,
    );
  }
  return WebViewController.fromPlatformCreationParams(
    params,
    onPermissionRequest: (request) async {
      try {
        await request.deny();
      } catch (_) {
        /* Never grant on failure. */
      }
    },
  );
}

/// Configures public plugin APIs; no JavaScript/native bridge is registered.
Future<void> restrictWebPanelPlatform(
  WebViewController controller,
  Future<void> Function(Future<void> Function()) step,
) async {
  await step(() => controller.setOnJavaScriptAlertDialog((_) async {}));
  await step(() => controller.setOnJavaScriptConfirmDialog((_) async => false));
  await step(() => controller.setOnJavaScriptTextInputDialog((_) async => ''));
  final platform = controller.platform;
  if (platform is AndroidWebViewController) {
    await step(() => platform.setAllowFileAccess(false));
    await step(() => platform.setAllowContentAccess(false));
    await step(() => platform.setGeolocationEnabled(false));
    await step(() => platform.setMixedContentMode(MixedContentMode.neverAllow));
    await step(() => platform.setMediaPlaybackRequiresUserGesture(true));
    await step(() => platform.setOnShowFileSelector((_) async => []));
    final cookies = WebViewCookieManager().platform;
    if (cookies is AndroidWebViewCookieManager) {
      await step(() => cookies.setAcceptThirdPartyCookies(platform, false));
    }
  }
}
