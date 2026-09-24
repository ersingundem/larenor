import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:larenor/features/web_panel/data/web_panel_platform.dart';
import 'package:larenor/features/web_panel/data/web_panel_renderer_monitor.dart';
import 'package:larenor/features/web_panel/domain/web_panel_policy.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('API 35 sandboxed srcdoc cannot create dynamic network egress', (
    tester,
  ) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final uri = Uri.parse('http://127.0.0.1:${server.port}/');
    final subscription = server.listen((request) async {
      request.response.headers.contentType = ContentType.html;
      request.response.write('''
<!doctype html><title>waiting</title><body><script>
window.addEventListener('message', (event) => { document.title = event.data; });
const frame = document.createElement('iframe');
frame.setAttribute('sandbox', 'allow-scripts');
frame.srcdoc = `<script>
const attempt = (name, operation) => {
  try { operation(); return name + ':allowed'; }
  catch (error) { return name + ':' + error.name; }
};
parent.postMessage([
  attempt('WebSocket', () => new WebSocket('ws://127.0.0.1:${server.port}/escape')),
  attempt('EventSource', () => new EventSource('/events')),
  attempt('WebTransport', () => new WebTransport('https://127.0.0.1:${server.port}/transport')),
  attempt('Worker', () => new Worker('data:text/javascript,postMessage(1)'))
].join(','), '*');
<\\/script>`;
document.body.append(frame);
</script></body>
''');
      await request.response.close();
    });
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

      const expected =
          'WebSocket:SecurityError,EventSource:SecurityError,'
          'WebTransport:SecurityError,Worker:SecurityError';
      String? title;
      for (var attempt = 0; attempt < 50; attempt++) {
        await tester.pump(const Duration(milliseconds: 100));
        title = await controller.getTitle();
        if (title == expected) break;
      }
      expect(title, expected);
    } finally {
      await handle?.dispose();
      await subscription.cancel();
      await server.close(force: true);
    }
  });
}
