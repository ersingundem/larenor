import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/home_resources/data/core_bounded_download_api.dart';
import 'package:larenor/features/home_resources/data/core_bounded_download_file_access.dart';
import 'package:larenor/features/home_resources/data/core_bounded_upload_file_access.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/trust_evidence_card.dart';

import '../../core/home_scope_fixture.dart' show flush;
import 'home_resources_fixture.dart';

bool fontsLoaded = false;
Future<void> loadFonts(WidgetTester tester) async {
  if (fontsLoaded) return;
  await tester.runAsync(() async {
    final font = await rootBundle.load('assets/fonts/Inter-Variable.ttf');
    for (final family in [
      'Inter',
      'CupertinoSystemText',
      'CupertinoSystemDisplay',
    ]) {
      await (FontLoader(family)..addFont(Future.value(font))).load();
    }
    await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(
          rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf'),
        ))
        .load();
  });
  fontsLoaded = true;
}

Uint8List _transferFrame(
  String trace,
  int sequence,
  bool finalFrame,
  List<int> payload,
) {
  final output = BytesBuilder(copy: false)
    ..add(ascii.encode('LRB1'))
    ..add(ascii.encode(trace));
  final fields = ByteData(13)
    ..setUint64(0, sequence)
    ..setUint8(8, finalFrame ? 1 : 0)
    ..setUint32(9, payload.length);
  output
    ..add(fields.buffer.asUint8List())
    ..add(payload);
  return output.takeBytes();
}

http.Response _transferResponse(http.Request request) {
  final trace = 'c' * 32;
  final payload = utf8.encode('tablet trust fixture');
  final digest = sha256.convert(payload).toString();
  final receipt = {
    'requestId': trace,
    'traceId': trace,
    'state': 'completed',
    'contentLength': payload.length,
    'sha256': digest,
    'contentType': 'application/octet-stream',
    'serviceRevision': 1,
    'createdAt': 10.0,
    'updatedAt': 11.0,
  };
  if (request.method == 'GET') {
    if (request.url.path.endsWith('/descriptor')) {
      return http.Response(
        jsonEncode({
          'blob': {
            'resourceId': '3' * 32,
            'serviceRevision': 1,
            'contentLength': payload.length,
            'sha256': digest,
            'contentType': 'application/octet-stream',
            'createdAt': 10.0,
            'updatedAt': 11.0,
          },
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.Response(
      jsonEncode(
        request.url.path.endsWith(trace)
            ? {'receipt': receipt}
            : {
                'receipts': [receipt],
              },
      ),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
  final wire = Uint8List.fromList([
    ..._transferFrame(trace, 0, false, payload),
    ..._transferFrame(trace, 1, true, const []),
  ]);
  return http.Response.bytes(
    wire,
    200,
    headers: {
      'content-type': CoreBoundedDownloadApi.wireType,
      'content-length': '${wire.length}',
      'x-larenor-trace-id': trace,
      'x-larenor-blob-content-length': '${payload.length}',
      'x-larenor-blob-sha256': digest,
      'x-larenor-blob-content-type': 'application/octet-stream',
      'x-larenor-service-revision': '1',
      'accept-ranges': 'none',
    },
  );
}

void main() {
  testWidgets('tablet resource exposes durable transfer trust semantically', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var saved = 0;
    final fixture = contract();
    final record = (fixture['memberList']['entries'] as List).last as Map;
    final id = (record['ref'] as Map)['id'] as String;
    final harness = ResourceHarness();
    harness.boundedDownloadApiFactory = (endpoint) => CoreBoundedDownloadApi(
      endpoint: endpoint,
      requestId: () => 'c' * 32,
      client: MockClient((request) async => _transferResponse(request)),
    );
    harness.boundedDownloadFileAccess = CoreBoundedDownloadFileAccess(
      save: (_, _, _) async {
        saved++;
        return Uri.parse('content://synthetic/tablet');
      },
    );
    try {
      await harness.mount(tester, width: 1200);
      await harness.signIn();
      await flush(tester);
      final download = find.byKey(ValueKey('core-resource-download-$id'));
      await tester.ensureVisible(download);
      await tester.tap(download);
      await flush(tester);
      for (var attempt = 0; attempt < 20 && saved == 0; attempt++) {
        await tester.pump(const Duration(milliseconds: 10));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      await flush(tester);

      final trust = find.byKey(ValueKey('core-resource-transfer-trust-$id'));
      expect(trust, findsOneWidget);
      expect(tester.getSemantics(trust).flagsCollection.isLiveRegion, isTrue);
      expect(
        tester.getSemantics(trust).label,
        allOf(
          contains('Transfer receipt verified'),
          contains('Request: registered'),
          contains('Service: reachable'),
          contains('Provider: accepted'),
          contains('Device result: saved'),
          contains('tablet trust fixture'.length.toString()),
        ),
      );
      expect(saved, 1);

      final changed = jsonDecode(jsonEncode(fixture['memberList'])) as Map;
      changed['userRevision'] = 8;
      changed['snapshot'] = 'f' * 64;
      harness.response = changed;
      final refresh = find.byKey(const ValueKey('home-resources-refresh'));
      await tester.ensureVisible(refresh);
      await tester.tap(refresh);
      await flush(tester);

      expect(
        find.byKey(ValueKey('core-resource-transfer-trust-$id')),
        findsNothing,
        reason: 'old receipt trust cannot survive a newer ACL snapshot',
      );
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
    'provider acceptance is not presented as device success after SAF cancel',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final fixture = contract();
      final record = (fixture['memberList']['entries'] as List).last as Map;
      final id = (record['ref'] as Map)['id'] as String;
      final harness = ResourceHarness();
      harness.boundedDownloadApiFactory = (endpoint) => CoreBoundedDownloadApi(
        endpoint: endpoint,
        requestId: () => 'c' * 32,
        client: MockClient((request) async => _transferResponse(request)),
      );
      harness.boundedDownloadFileAccess = CoreBoundedDownloadFileAccess(
        save: (_, _, _) async => null,
      );
      try {
        await harness.mount(tester, width: 600);
        await harness.signIn();
        await flush(tester);
        final download = find.byKey(ValueKey('core-resource-download-$id'));
        await tester.ensureVisible(download);
        await tester.tap(download);
        for (
          var attempt = 0;
          attempt < 20 && find.text('Transfer incomplete').evaluate().isEmpty;
          attempt++
        ) {
          await tester.pump(const Duration(milliseconds: 10));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }

        final trust = find.byKey(ValueKey('core-resource-transfer-trust-$id'));
        expect(trust, findsOneWidget);
        expect(
          tester.getSemantics(trust).label,
          allOf(
            contains('Transfer incomplete'),
            contains('Request: registered'),
            contains('Service: reachable'),
            contains('Provider: accepted'),
            contains('Device result: not saved'),
            isNot(contains('Transfer receipt verified')),
          ),
        );
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'background retires a verified receipt before a late SAF result',
    (tester) async {
      final destination = Completer<Uri?>();
      var saveRequests = 0;
      final fixture = contract();
      final record = (fixture['memberList']['entries'] as List).last as Map;
      final id = (record['ref'] as Map)['id'] as String;
      final harness = ResourceHarness();
      harness.boundedDownloadApiFactory = (endpoint) => CoreBoundedDownloadApi(
        endpoint: endpoint,
        requestId: () => 'c' * 32,
        client: MockClient((request) async => _transferResponse(request)),
      );
      harness.boundedDownloadFileAccess = CoreBoundedDownloadFileAccess(
        save: (_, _, _) {
          saveRequests++;
          return destination.future;
        },
      );
      try {
        await harness.mount(tester, width: 1200);
        await harness.signIn();
        await flush(tester);
        final download = find.byKey(ValueKey('core-resource-download-$id'));
        await tester.ensureVisible(download);
        await tester.tap(download);
        for (var attempt = 0; attempt < 20 && saveRequests == 0; attempt++) {
          await tester.pump(const Duration(milliseconds: 10));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }

        expect(saveRequests, 1);
        await tester.pump();
        final trust = find.byKey(ValueKey('core-resource-transfer-trust-$id'));
        expect(trust, findsOneWidget);
        expect(
          tester.widget<TrustEvidenceCard>(trust).state,
          TrustEvidenceState.checking,
          reason: 'provider acceptance is not a device save result',
        );

        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await flush(tester);
        destination.complete(Uri.parse('content://synthetic/late'));
        await flush(tester);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await flush(tester);

        expect(download, findsOneWidget);
        expect(
          find.byKey(ValueKey('core-resource-transfer-trust-$id')),
          findsNothing,
          reason: 'a late SAF completion cannot restore retired trust',
        );
        expect(find.textContaining('Transfer receipt verified'), findsNothing);
        expect(
          saveRequests,
          1,
          reason: 'foreground recovery never retries SAF',
        );
      } finally {
        if (!destination.isCompleted) destination.complete(null);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }
    },
  );

  testWidgets(
    'account and home switch reject the previous home late SAF result',
    (tester) async {
      final destination = Completer<Uri?>();
      var saveRequests = 0, transferRequests = 0;
      final fixture = contract();
      final record = (fixture['memberList']['entries'] as List).last as Map;
      final id = (record['ref'] as Map)['id'] as String;
      final harness = ResourceHarness();
      harness.boundedDownloadApiFactory = (endpoint) => CoreBoundedDownloadApi(
        endpoint: endpoint,
        requestId: () => 'c' * 32,
        client: MockClient((request) async {
          transferRequests++;
          return _transferResponse(request);
        }),
      );
      harness.boundedDownloadFileAccess = CoreBoundedDownloadFileAccess(
        save: (_, _, _) {
          saveRequests++;
          return destination.future;
        },
      );
      try {
        await harness.mount(tester, width: 1200);
        await harness.signIn();
        await flush(tester);
        final download = find.byKey(ValueKey('core-resource-download-$id'));
        await tester.ensureVisible(download);
        await tester.tap(download);
        for (var attempt = 0; attempt < 20 && saveRequests == 0; attempt++) {
          await tester.pump(const Duration(milliseconds: 10));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        expect((transferRequests, saveRequests), (3, 1));

        await harness.account.signOut();
        harness.userId = '8' * 32;
        harness.contextResponse = fixture['otherContextList']['scope'];
        harness.response = fixture['otherContextList'];
        await harness.signIn();
        await flush(tester);
        expect(find.text('İkinci ev · Salon'), findsOneWidget);

        destination.complete(Uri.parse('content://synthetic/previous-home'));
        await flush(tester);

        expect(find.text('İkinci ev · Salon'), findsOneWidget);
        expect(
          find.byKey(ValueKey('core-resource-transfer-trust-$id')),
          findsNothing,
          reason: 'the previous home receipt cannot enter the new home view',
        );
        expect(
          (transferRequests, saveRequests),
          (3, 1),
          reason: 'an account switch never replays the old transfer',
        );
      } finally {
        if (!destination.isCompleted) destination.complete(null);
      }
    },
  );

  for (final locale in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets('writable blob upload is accessible at $locale $width 2x', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        final fixture = contract();
        final writable = jsonDecode(jsonEncode(fixture['memberList'])) as Map;
        final rawTarget = (writable['entries'] as List).cast<Map>().firstWhere(
          (entry) => (entry['ref'] as Map)['id'] == '3' * 32,
        );
        (rawTarget['permissions'] as Map)['write'] = true;
        final targetId = (rawTarget['ref'] as Map)['id'] as String;
        final payload = Uint8List.fromList(utf8.encode('tablet attachment'));
        final digest = sha256.convert(payload).toString();
        final harness = ResourceHarness()..response = writable;
        harness.boundedUploadFileAccess = CoreBoundedUploadFileAccess(
          pick: () async => CoreBoundedPickedFile(
            name: 'warranty.pdf',
            declaredLength: payload.length,
            chunks: Stream.value(payload),
          ),
        );
        harness.boundedDownloadApiFactory = (endpoint) =>
            CoreBoundedDownloadApi(
              endpoint: endpoint,
              requestId: () => '8' * 32,
              client: MockClient((request) async {
                if (request.url.path.endsWith('/descriptor')) {
                  return http.Response(
                    '{"error":{"code":"not_found"}}',
                    404,
                    headers: {'content-type': 'application/json'},
                  );
                }
                return http.Response(
                  jsonEncode({
                    'blob': {
                      'requestId': '8' * 32,
                      'resourceId': targetId,
                      'serviceRevision': 1,
                      'contentLength': payload.length,
                      'sha256': digest,
                      'contentType': 'application/pdf',
                      'createdAt': 10.0,
                      'updatedAt': 10.0,
                    },
                  }),
                  201,
                  headers: {'content-type': 'application/json'},
                );
              }),
            );
        try {
          await harness.mount(tester, locale: locale, width: width, scale: 2);
          await harness.signIn();
          await flush(tester);
          final refresh = find.byKey(const ValueKey('home-resources-refresh'));
          await tester.scrollUntilVisible(
            refresh,
            400,
            scrollable: find.byType(Scrollable).first,
            maxScrolls: 20,
          );
          await tester.pump();
          await tester.tap(refresh);
          await flush(tester);
          final upload = find.byKey(ValueKey('core-resource-upload-$targetId'));
          await tester.scrollUntilVisible(
            upload,
            400,
            scrollable: find.byType(Scrollable).first,
            maxScrolls: 20,
          );
          await tester.pump();
          expect(tester.getSize(upload).height, greaterThanOrEqualTo(48));
          await tester.tap(upload);
          final completed = locale == 'tr' ? 'revizyon 1' : 'revision 1';
          for (var attempt = 0; attempt < 30; attempt++) {
            await tester.pump(const Duration(milliseconds: 10));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 5)),
            );
            if (find.textContaining(completed).evaluate().isNotEmpty) break;
          }
          await flush(tester);
          final status = find.byKey(
            ValueKey('core-resource-upload-status-$targetId'),
          );
          expect(status, findsOneWidget);
          expect(tester.getSemantics(status).label, contains(completed));
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });
    }
  }

  for (final locale in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      for (final dark in [false, true]) {
        testWidgets(
          'Core resources real-font $locale $width ${dark ? 'dark' : 'light'} 2x',
          (tester) async {
            await loadFonts(tester);
            final semantics = tester.ensureSemantics();
            try {
              tester.platformDispatcher.platformBrightnessTestValue = dark
                  ? Brightness.dark
                  : Brightness.light;
              addTearDown(
                tester.platformDispatcher.clearPlatformBrightnessTestValue,
              );
              final h = ResourceHarness()..response = contract()['adminList'];
              await h.mount(tester, locale: locale, width: width, scale: 2);
              await h.signIn();
              await flush(tester);
              final refresh = find.byKey(
                const ValueKey('home-resources-refresh'),
              );
              final l10n = AppLocalizations.of(tester.element(refresh));
              final title = find.text(l10n.homeResourcesTitle);
              await tester.ensureVisible(title);
              await flush(tester);
              expect(
                tester.getSemantics(title).flagsCollection.isHeader,
                isTrue,
              );
              await tester.ensureVisible(refresh);
              await flush(tester);
              final refreshNode = tester.getSemantics(
                find.text(l10n.commonRefresh),
              );
              expect(refreshNode.label, l10n.commonRefresh);
              expect(refreshNode.flagsCollection.isButton, isTrue);
              expect(refreshNode.flagsCollection.isHeader, isFalse);
              expect(refreshNode.rect.height, greaterThanOrEqualTo(48));
              expect(find.bySemanticsLabel(l10n.commonRefresh), findsOneWidget);
              final caption = find.text(l10n.commonRefresh);
              Focus.of(tester.element(caption)).requestFocus();
              await flush(tester);
              expect(Focus.of(tester.element(caption)).hasPrimaryFocus, isTrue);
              // The preceding source action and refresh remain distinct tab targets.
              await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
              await tester.sendKeyEvent(LogicalKeyboardKey.tab);
              await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
              await flush(tester);
              expect(
                Focus.of(tester.element(find.text(l10n.homeSourceTitle)))
                    .hasPrimaryFocus,
                isTrue,
              );
              await tester.sendKeyEvent(LogicalKeyboardKey.tab);
              await flush(tester);
              expect(Focus.of(tester.element(caption)).hasPrimaryFocus, isTrue);
              final count = h.resourceReads;
              await tester.sendKeyEvent(LogicalKeyboardKey.enter);
              await flush(tester);
              expect(h.resourceReads, count + 1);
              await tester.sendKeyEvent(LogicalKeyboardKey.space);
              await flush(tester);
              expect(h.resourceReads, count + 2);
              final focusDecorations = find.descendant(
                of: refresh,
                matching: find.byWidgetPredicate(
                  (w) =>
                      w is DecoratedBox &&
                      w.decoration is ShapeDecoration &&
                      (w.decoration as ShapeDecoration).shape is OutlinedBorder,
                ),
              );
              final outline =
                  (tester
                                  .widget<DecoratedBox>(focusDecorations.first)
                                  .decoration
                              as ShapeDecoration)
                          .shape
                      as OutlinedBorder;
              final background = CupertinoTheme.of(tester.element(refresh))
                  .scaffoldBackgroundColor;
              final lighter = outline.side.color.computeLuminance(),
                  darker = background.computeLuminance();
              final contrast =
                  ((lighter > darker ? lighter : darker) + .05) /
                  ((lighter < darker ? lighter : darker) + .05);
              expect(contrast, greaterThanOrEqualTo(3));
              await tester.ensureVisible(refresh);
              await flush(tester);
              final rect = tester.getRect(refresh);
              expect(rect.left, greaterThanOrEqualTo(4));
              expect(rect.right, lessThanOrEqualTo(width - 4));
              const output = String.fromEnvironment(
                'CORE_RESOURCES_PREVIEW_DIR',
              );
              if (output.isNotEmpty) {
                await tester.runAsync(() async {
                  final render =
                      h.boundary.currentContext!.findRenderObject()!
                          as RenderRepaintBoundary;
                  final picture = await render.toImage(pixelRatio: 1);
                  try {
                    final png = await picture.toByteData(
                      format: ui.ImageByteFormat.png,
                    );
                    Directory(output).createSync(recursive: true);
                    File(
                      '$output/core-resources-$locale-${width.toInt()}-2x-${dark ? 'dark' : 'light'}.png',
                    ).writeAsBytesSync(png!.buffer.asUint8List());
                  } finally {
                    picture.dispose();
                  }
                });
              }
              final unicode = h.fixture['unicodeRecord']['record'];
              final last = find.byKey(
                ValueKey('home-resource-${unicode['ref']['id']}'),
              );
              await tester.scrollUntilVisible(
                last,
                400,
                scrollable: find.byType(Scrollable).first,
                maxScrolls: 20,
              );
              await flush(tester);
              expect(find.text(unicode['label'] as String), findsOneWidget);
              final download = find.byKey(
                ValueKey(
                  'core-resource-download-${unicode['ref']['id'] as String}',
                ),
              );
              await tester.ensureVisible(download);
              await flush(tester);
              expect(tester.getRect(download).height, greaterThanOrEqualTo(48));
              final downloadLabel =
                  '${l10n.coreResourceDownload}: ${unicode['label'] as String}';
              final downloadText = find.text(downloadLabel);
              expect(downloadText, findsOneWidget);
              final downloadNode = tester.getSemantics(downloadText);
              expect(downloadNode.flagsCollection.isButton, isTrue);
              Focus.of(tester.element(downloadText)).requestFocus();
              await flush(tester);
              expect(
                Focus.of(tester.element(downloadText)).hasPrimaryFocus,
                isTrue,
              );
              final history = find.byKey(
                ValueKey(
                  'core-resource-transfer-history-${unicode['ref']['id'] as String}',
                ),
              );
              await tester.ensureVisible(history);
              await flush(tester);
              expect(tester.getRect(history).height, greaterThanOrEqualTo(48));
              final historyLabel =
                  '${l10n.coreResourceTransferHistory}: ${unicode['label'] as String}';
              final historyText = find.text(historyLabel);
              expect(historyText, findsOneWidget);
              expect(
                tester.getSemantics(historyText).flagsCollection.isButton,
                isTrue,
              );
              await tester.tap(historyText);
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)),
              );
              await flush(tester);
              expect(
                find.byKey(
                  ValueKey('core-resource-transfer-receipt-${'c' * 32}'),
                ),
                findsOneWidget,
              );
              expect(
                find.text(l10n.coreResourceTransferCompleted),
                findsOneWidget,
              );
              expect(find.text('16 B · text/plain'), findsOneWidget);
              for (final element
                  in find
                      .descendant(of: last, matching: find.byType(RichText))
                      .evaluate()) {
                final paragraph = element.renderObject! as RenderParagraph;
                expect(paragraph.didExceedMaxLines, isFalse);
                expect(paragraph.size.width, lessThanOrEqualTo(width - 48));
              }
              expect(tester.takeException(), isNull);
              expect(h.haReads, 0);
            } finally {
              semantics.dispose();
            }
          },
        );
      }
    }
  }
}
