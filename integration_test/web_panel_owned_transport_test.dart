import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:larenor/features/web_panel/data/web_panel_platform.dart';
import 'package:larenor/features/web_panel/data/web_panel_renderer_monitor.dart';
import 'package:larenor/features/web_panel/domain/web_panel_policy.dart';
import 'package:webview_flutter/webview_flutter.dart';

const _oversizeBodyBytes = 16 * 1024 * 1024 + 1;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'API 35 owned transport contains redirects and oversized responses',
    (tester) async {
      if (defaultTargetPlatform != TargetPlatform.android) return;
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final foreign = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final originPaths = <String>[];
      var foreignRequests = 0;
      final foreignSubscription = foreign.listen((request) async {
        foreignRequests++;
        request.response.headers.contentType = ContentType(
          'application',
          'javascript',
        );
        request.response.write('window.foreignLoaded = true;');
        await request.response.close();
      });
      final originSubscription = origin.listen((request) async {
        originPaths.add(request.uri.path);
        switch (request.uri.path) {
          case '/':
            request.response.headers.contentType = ContentType.html;
            request.response.write('''
<!doctype html><title>waiting</title><body>
<script>window.redirectLoaded = false; window.foreignLoaded = false; window.oversizeLoaded = false;</script>
<script src="/redirect"></script>
<script src="/escape"></script>
<script src="/oversize"></script>
<script>
setTimeout(() => {
  document.title = [
    window.redirectLoaded ? 'redirect:loaded' : 'redirect:blocked',
    window.foreignLoaded ? 'foreign:loaded' : 'foreign:blocked',
    window.oversizeLoaded ? 'oversize:loaded' : 'oversize:blocked'
  ].join(',');
}, 100);
</script>
</body>
''');
            await request.response.close();
          case '/redirect':
            request.response.statusCode = HttpStatus.found;
            request.response.headers.set(
              HttpHeaders.locationHeader,
              '/asset.js',
            );
            await request.response.close();
          case '/asset.js':
            request.response.headers.contentType = ContentType(
              'application',
              'javascript',
            );
            request.response.write('window.redirectLoaded = true;');
            await request.response.close();
          case '/escape':
            request.response.statusCode = HttpStatus.found;
            request.response.headers.set(
              HttpHeaders.locationHeader,
              'http://127.0.0.1:${foreign.port}/foreign.js',
            );
            await request.response.close();
          case '/oversize':
            request.response.headers.contentType = ContentType(
              'application',
              'javascript',
            );
            request.response.contentLength = _oversizeBodyBytes;
            await request.response.flush();
            unawaited(request.response.close().catchError((_) {}));
          default:
            request.response.statusCode = HttpStatus.notFound;
            await request.response.close();
        }
      });
      final uri = Uri.parse('http://127.0.0.1:${origin.port}/');
      final controller = createWebPanelController();
      final policy = WebPanelPolicy.fromUrl(uri.toString())!;
      WebPanelRendererHandle? handle;
      try {
        handle = await WebPanelRendererChannel().attach(
          controller,
          policy.allowedOrigins,
          () {},
        );
        expect(handle, isNotNull);
        await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
        await tester.pumpWidget(
          CupertinoApp(home: WebViewWidget(controller: controller)),
        );
        await controller.loadRequest(uri);

        const expected = 'redirect:loaded,foreign:blocked,oversize:blocked';
        expect(await _waitForTitle(tester, controller, expected), expected);
        expect(
          originPaths,
          containsAll(<String>[
            '/',
            '/redirect',
            '/asset.js',
            '/escape',
            '/oversize',
          ]),
        );
        expect(foreignRequests, 0);
      } finally {
        await handle?.dispose();
        await originSubscription.cancel();
        await foreignSubscription.cancel();
        await origin.close(force: true);
        await foreign.close(force: true);
      }
    },
  );
}

Future<String?> _waitForTitle(
  WidgetTester tester,
  WebViewController controller,
  String expected,
) async {
  String? title;
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
    title = await controller.getTitle();
    if (title == expected) return title;
  }
  return title;
}
