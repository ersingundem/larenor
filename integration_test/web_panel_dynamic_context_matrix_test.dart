import 'dart:convert';
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

  testWidgets(
    'API 35 applies dynamic egress policy to every frame and reload',
    (tester) async {
      if (defaultTargetPlatform != TargetPlatform.android) return;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final uri = Uri.parse('http://127.0.0.1:${server.port}/');
      var rootLoads = 0;
      final probe = _probeScript(server.port);
      final encodedProbe = jsonEncode(probe);
      final subscription = server.listen((request) async {
        request.response.headers.contentType = ContentType.html;
        if (request.uri.path == '/frame') {
          request.response.write('''
<!doctype html><body><script>
$probe
parent.postMessage({label: 'frame', value: runProbe()}, '*');
</script></body>
''');
        } else {
          rootLoads++;
          request.response.write('''
<!doctype html><title>waiting</title><body><script>
$probe
const results = {};
const publish = (label, value) => {
  results[label] = value;
  if (Object.keys(results).length === 4) {
    document.title = Object.keys(results).sort()
      .map(key => key + '=' + results[key]).join(';');
  }
};
window.addEventListener('message', event => publish(event.data.label, event.data.value));
publish('top', runProbe());

const sameOrigin = document.createElement('iframe');
sameOrigin.src = '/frame';
document.body.append(sameOrigin);

const opaqueProbe = $encodedProbe;
const appendOpaque = label => {
  const frame = document.createElement('iframe');
  frame.setAttribute('sandbox', 'allow-scripts');
  frame.srcdoc = '<script>' + opaqueProbe +
    '\\nparent.postMessage({label: ' + JSON.stringify(label) +
    ', value: runProbe()}, "*");<\\/script>';
  document.body.append(frame);
};
appendOpaque('opaque');
setTimeout(() => appendOpaque('delayed'), 50);
</script></body>
''');
        }
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

        final expectedProbe =
            'WebSocket:SecurityError,EventSource:SecurityError,'
            'WebTransport:SecurityError,Worker:SecurityError,'
            'SharedWorker:SecurityError';
        final expected =
            'delayed=$expectedProbe;frame=$expectedProbe;'
            'opaque=$expectedProbe;top=$expectedProbe';
        expect(await _waitForTitle(tester, controller, expected), expected);

        await controller.reload();
        for (var attempt = 0; attempt < 80 && rootLoads < 2; attempt++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(rootLoads, 2);
        expect(await _waitForTitle(tester, controller, expected), expected);
      } finally {
        await handle?.dispose();
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );
}

String _probeScript(int port) =>
    '''
const attempt = (name, operation) => {
  try { operation(); return name + ':allowed'; }
  catch (error) { return name + ':' + error.name; }
};
const runProbe = () => [
  attempt('WebSocket', () => new WebSocket('ws://127.0.0.1:$port/escape')),
  attempt('EventSource', () => new EventSource('/events')),
  attempt('WebTransport', () => new WebTransport('https://127.0.0.1:$port/transport')),
  attempt('Worker', () => new Worker('data:text/javascript,postMessage(1)')),
  attempt('SharedWorker', () => new SharedWorker('data:text/javascript,onconnect=()=>{}'))
].join(',');
''';

Future<String?> _waitForTitle(
  WidgetTester tester,
  WebViewController controller,
  String expected,
) async {
  String? title;
  for (var attempt = 0; attempt < 80; attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
    title = await controller.getTitle();
    if (title == expected) return title;
  }
  return title;
}
