import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/dashboard/presentation/tiles/webview_tile.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

// Exercise the public WebViewController wrapper and platform contracts. This
// fake never creates a browser engine, fetches a URL, or uses native channels.
class TestWebViewPlatform extends WebViewPlatform {
  final controllers = <_Controller>[];
  Completer<void>? nextDelegateGate;
  Completer<void>? nextJavaScriptGate;
  bool failNextLoad = false;

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    final controller = _Controller(
      params,
      delegateGate: nextDelegateGate,
      javaScriptGate: nextJavaScriptGate,
      failLoad: failNextLoad,
    );
    nextDelegateGate = null;
    nextJavaScriptGate = null;
    failNextLoad = false;
    controllers.add(controller);
    return controller;
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _Delegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _WebWidget(params);
}

class _Controller extends PlatformWebViewController {
  _Controller(
    super.params, {
    this.delegateGate,
    this.javaScriptGate,
    this.failLoad = false,
  }) : super.implementation();
  final Completer<void>? delegateGate, javaScriptGate;
  final bool failLoad;
  final requests = <LoadRequestParams>[];
  final modes = <JavaScriptMode>[];
  final html = <String>[];
  final htmlBaseUrls = <String?>[];
  @override
  Future<void> setBackgroundColor(Color color) async {}

  late _Delegate delegate;
  late void Function(PlatformWebViewPermissionRequest) permission;

  @override
  Future<void> setOnPlatformPermissionRequest(
    void Function(PlatformWebViewPermissionRequest) callback,
  ) async => permission = callback;

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {
    delegate = handler as _Delegate;
    if (delegateGate != null) await delegateGate!.future;
  }

  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {
    modes.add(mode);
    if (mode == JavaScriptMode.unrestricted && javaScriptGate != null) {
      await javaScriptGate!.future;
    }
  }

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    requests.add(params);
    if (failLoad) throw StateError('private.server/token=do-not-render');
  }

  @override
  Future<void> loadHtmlString(String value, {String? baseUrl}) async {
    html.add(value);
    htmlBaseUrls.add(baseUrl);
  }
}

class _Delegate extends PlatformNavigationDelegate {
  _Delegate(super.params) : super.implementation();
  late NavigationRequestCallback navigation;
  late PageEventCallback started, finished;
  late WebResourceErrorCallback resourceError;
  late HttpAuthRequestCallback auth;
  late SslAuthErrorCallback ssl;

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback callback,
  ) async => navigation = callback;
  @override
  Future<void> setOnPageStarted(PageEventCallback callback) async =>
      started = callback;
  @override
  Future<void> setOnPageFinished(PageEventCallback callback) async =>
      finished = callback;
  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback callback) async =>
      resourceError = callback;
  @override
  Future<void> setOnHttpAuthRequest(HttpAuthRequestCallback callback) async =>
      auth = callback;
  @override
  Future<void> setOnSSlAuthError(SslAuthErrorCallback callback) async =>
      ssl = callback;
}

class _WebWidget extends PlatformWebViewWidget {
  _WebWidget(super.params) : super.implementation();
  @override
  Widget build(BuildContext context) => const ColoredBox(
    key: ValueKey('fake-web-content'),
    color: CupertinoColors.white,
  );
}

class TestWebViewPermission extends PlatformWebViewPermissionRequest {
  TestWebViewPermission()
    : super(
        types: {
          WebViewPermissionResourceType.camera,
          WebViewPermissionResourceType.microphone,
        },
      );
  final decisions = <String>[];
  @override
  Future<void> grant() async => decisions.add('grant');
  @override
  Future<void> deny() async => decisions.add('deny');
}

class TestWebViewSslError extends PlatformSslAuthError {
  TestWebViewSslError()
    : super(certificate: null, description: 'private.invalid/token=secret');
  final decisions = <String>[];
  @override
  Future<void> cancel() async => decisions.add('cancel');
  @override
  Future<void> proceed() async => decisions.add('proceed');
}

class _Harness {
  _Harness({String url = 'https://dashboard.example/status'})
    : url = ValueNotifier(url);
  final platform = TestWebViewPlatform();
  final ValueNotifier<String> url;
  final visible = ValueNotifier(true);
  final mounted = ValueNotifier(true);
  late AppLocalizations l10n;

  Future<void> mount(WidgetTester tester) async {
    final previous = WebViewPlatform.instance;
    WebViewPlatform.instance = platform;
    addTearDown(() {
      // The interface deliberately forbids setting its singleton to null.
      WebViewPlatform.instance = previous ?? TestWebViewPlatform();
      url.dispose();
      visible.dispose();
      mounted.dispose();
    });
    await tester.pumpWidget(
      CupertinoApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            l10n = AppLocalizations.of(context);
            return CupertinoPageScaffold(
              child: Center(
                child: SizedBox(
                  width: 300,
                  height: 250,
                  child: ListenableBuilder(
                    listenable: Listenable.merge([url, visible, mounted]),
                    builder: (_, _) => TickerMode(
                      enabled: visible.value,
                      child: mounted.value
                          ? WebviewTile(
                              key: const ValueKey('card'),
                              tile: TileConfig(
                                id: 'website',
                                type: TileType.webview,
                                x: 0,
                                y: 0,
                                width: 2,
                                height: 2,
                                url: url.value,
                              ),
                            )
                          : const SizedBox(),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }
}

const _privateError = WebResourceError(
  errorCode: -1,
  description: 'private.server/token=secret',
  isForMainFrame: true,
);

void _pause(WidgetTester tester) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
}

void _resume(WidgetTester tester) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

void main() {
  testWidgets('valid card loads once without native credentials or headers', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester);
    final controller = h.platform.controllers.single;
    expect(controller.requests.single.uri.toString(), h.url.value);
    expect(controller.requests.single.headers, isEmpty);
    expect(controller.requests.single.body, isNull);
    expect(controller.requests.single.method, LoadRequestMethod.get);
    expect(controller.modes, [JavaScriptMode.unrestricted]);
    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
    controller.delegate.finished(h.url.value);
    await tester.pump();
    expect(find.byType(CupertinoActivityIndicator), findsNothing);
    expect(find.byKey(const ValueKey('fake-web-content')), findsOneWidget);
    await h.close(tester);
    expect(controller.modes.last, JavaScriptMode.disabled);
    await tester.pump();
    expect(controller.html, ['<html></html>']);
    expect(controller.htmlBaseUrls, [null]);
  });

  for (final url in [
    'javascript:alert(1)',
    'file:///sdcard/secret',
    'intent://launch',
    'https://user:secret@dashboard.example',
    'https://dashboard.example/%0aSecret',
    'https://dashboard.example\\@other.example',
    'http://',
  ]) {
    testWidgets('invalid legacy URL never creates a controller: $url', (
      tester,
    ) async {
      final h = _Harness(url: url);
      await h.mount(tester);
      expect(h.platform.controllers, isEmpty);
      expect(find.text(h.l10n.homeInvalidUrl), findsOneWidget);
      await tester.tap(find.text(h.l10n.commonRetry));
      await tester.pump();
      expect(h.platform.controllers, isEmpty);
      await h.close(tester);
    });
  }

  for (final stage in ['delegate', 'javascript']) {
    for (final retirement in ['url', 'unmount', 'hidden', 'background']) {
      testWidgets('late $stage after $retirement cannot load the old URL', (
        tester,
      ) async {
        final h = _Harness();
        final gate = Completer<void>();
        if (stage == 'delegate') {
          h.platform.nextDelegateGate = gate;
        } else {
          h.platform.nextJavaScriptGate = gate;
        }
        await h.mount(tester);
        final retired = h.platform.controllers.single;
        expect(retired.requests, isEmpty);
        switch (retirement) {
          case 'url':
            h.url.value = 'https://new.example/';
          case 'unmount':
            h.mounted.value = false;
          case 'hidden':
            h.visible.value = false;
          case 'background':
            _pause(tester);
        }
        await tester.pump();
        gate.complete();
        await tester.pump();
        expect(retired.requests, isEmpty);
        expect(retired.modes.last, JavaScriptMode.disabled);
        await tester.pump();
        expect(retired.html, ['<html></html>']);
        expect(retired.htmlBaseUrls, [null]);
        if (retirement == 'url') {
          expect(
            h.platform.controllers.last.requests.single.uri.host,
            'new.example',
          );
        }
        if (retirement == 'background') _resume(tester);
        await h.close(tester);
      });
    }
  }

  testWidgets('old page callbacks cannot fail or finish the replacement', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester);
    final old = h.platform.controllers.single;
    h.url.value = 'https://replacement.example/';
    await tester.pump();
    final current = h.platform.controllers.last;
    old.delegate.finished('https://old.example/');
    old.delegate.resourceError(_privateError);
    final oldSsl = TestWebViewSslError();
    old.delegate.ssl(oldSsl);
    await tester.pump();
    expect(oldSsl.decisions, ['cancel']);
    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
    expect(find.text(h.l10n.commonError), findsNothing);
    current.delegate.finished(h.url.value);
    await tester.pump();
    old.delegate.started('https://old.example/');
    await tester.pump();
    expect(find.byType(CupertinoActivityIndicator), findsNothing);
    expect(current.html, isEmpty);
    await h.close(tester);
  });

  testWidgets(
    'navigation rejects unsafe schemes, credentials and old generation',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      final callback = h.platform.controllers.single.delegate.navigation;
      for (final url in [
        'javascript:alert(1)',
        'file:///secret',
        'data:text/html,secret',
        'intent://launch',
        'https://user:secret@example.com',
        'https://example.com/%0dHeader',
        'https://example.com\\@evil.test',
      ]) {
        for (final main in [true, false]) {
          expect(
            await callback(NavigationRequest(url: url, isMainFrame: main)),
            NavigationDecision.prevent,
          );
        }
      }
      expect(
        await callback(
          const NavigationRequest(
            url: 'http://192.0.2.1/ui',
            isMainFrame: true,
          ),
        ),
        NavigationDecision.navigate,
      );
      h.visible.value = false;
      await tester.pump();
      expect(
        await callback(
          const NavigationRequest(
            url: 'https://example.com',
            isMainFrame: true,
          ),
        ),
        NavigationDecision.prevent,
      );
      await h.close(tester);
    },
  );

  testWidgets('permissions and HTTP auth are denied including late callbacks', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester);
    final controller = h.platform.controllers.single;
    for (final retired in [false, true]) {
      if (retired) await h.close(tester);
      final permission = TestWebViewPermission();
      controller.permission(permission);
      final auth = <String>[];
      controller.delegate.auth(
        HttpAuthRequest(
          host: 'private.example',
          onProceed: (_) => auth.add('proceed'),
          onCancel: () => auth.add('cancel'),
        ),
      );
      await tester.pump();
      expect(permission.decisions, ['deny']);
      expect(auth, ['cancel']);
    }
  });

  testWidgets('TLS failure cancels and retires page with generic retry UI', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester);
    final old = h.platform.controllers.single;
    final ssl = TestWebViewSslError();
    old.delegate.ssl(ssl);
    await tester.pump();
    expect(ssl.decisions, ['cancel']);
    expect(old.modes.last, JavaScriptMode.disabled);
    await tester.pump();
    expect(old.html, ['<html></html>']);
    expect(old.htmlBaseUrls, [null]);
    expect(find.text(h.l10n.commonError), findsOneWidget);
    expect(find.textContaining('private.invalid'), findsNothing);
    await tester.tap(find.text(h.l10n.commonRetry));
    await tester.pump();
    expect(h.platform.controllers, hasLength(2));
    expect(h.platform.controllers.last.requests, hasLength(1));
    await h.close(tester);
  });

  testWidgets('subresource error does not fail card, main error is redacted', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester);
    final controller = h.platform.controllers.single;
    controller.delegate.resourceError(
      const WebResourceError(
        errorCode: -1,
        description: 'subresource',
        isForMainFrame: false,
      ),
    );
    await tester.pump();
    expect(find.text(h.l10n.commonError), findsNothing);
    controller.delegate.resourceError(_privateError);
    await tester.pump();
    expect(find.text(h.l10n.commonError), findsOneWidget);
    expect(find.textContaining('private.server'), findsNothing);
    await tester.pump();
    expect(controller.html, ['<html></html>']);
    expect(controller.htmlBaseUrls, [null]);
    await h.close(tester);
  });

  testWidgets(
    'platform load failure is caught and contains no private detail',
    (tester) async {
      final h = _Harness();
      h.platform.failNextLoad = true;
      await h.mount(tester);
      expect(find.text(h.l10n.commonError), findsOneWidget);
      expect(find.textContaining('private.server'), findsNothing);
      expect(tester.takeException(), isNull);
      await h.close(tester);
    },
  );

  testWidgets(
    'hidden initial card creates no controller; each resume reloads once',
    (tester) async {
      final h = _Harness();
      h.visible.value = false;
      await h.mount(tester);
      expect(h.platform.controllers, isEmpty);
      h.visible.value = true;
      await tester.pump();
      final first = h.platform.controllers.single;
      expect(first.requests, hasLength(1));
      _pause(tester);
      await tester.pump();
      await tester.pump();
      expect(first.html, ['<html></html>']);
      expect(first.htmlBaseUrls, [null]);
      await tester.pump(const Duration(minutes: 1));
      expect(h.platform.controllers, hasLength(1));
      _resume(tester);
      await tester.pump();
      expect(h.platform.controllers, hasLength(2));
      expect(h.platform.controllers.last.requests, hasLength(1));
      await h.close(tester);
    },
  );
}
