import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/ambient/data/ambient_content_repository.dart';
import 'package:larenor/features/ambient/domain/ambient_content.dart';
import 'package:larenor/features/ambient/presentation/ambient_content_sequence.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import '../dashboard/webview_tile_test.dart' show TestWebViewPlatform;

class _Repository implements AmbientContentStore {
  final failed = <String>{};
  final reads = <String>[];
  @override
  Future<Uint8List> readLocal(AmbientContent item) async {
    reads.add(item.id);
    if (failed.contains(item.id)) throw const AmbientContentException();
    return Uint8List.fromList('%PDF-1.7\n%%EOF'.codeUnits);
  }
}

void main() {
  testWidgets('ambient web blocks same-origin secret-bearing redirects', (
    tester,
  ) async {
    final previous = WebViewPlatform.instance;
    final platform = TestWebViewPlatform();
    WebViewPlatform.instance = platform;
    addTearDown(
      () => WebViewPlatform.instance = previous ?? TestWebViewPlatform(),
    );
    final item = AmbientContent.web(
      id: '9' * 64,
      url: 'https://panel.example/status',
    );
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AmbientContentSequence(
          repository: _Repository(),
          items: [item],
          interval: const Duration(minutes: 1),
          active: true,
          reducedMotion: true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final delegate = platform.controllers.single.delegate;
    expect(
      await delegate.navigation(
        const NavigationRequest(
          url: 'https://panel.example/status?token=private',
          isMainFrame: true,
        ),
      ),
      NavigationDecision.prevent,
    );
  });

  testWidgets('skips broken content and retires callbacks when inactive', (
    tester,
  ) async {
    final repository = _Repository()..failed.add('a' * 64);
    final items = [
      AmbientContent.local(
        id: 'a' * 64,
        kind: AmbientContentKind.pdf,
        sizeBytes: 16,
      ),
      AmbientContent.local(
        id: 'b' * 64,
        kind: AmbientContentKind.pdf,
        sizeBytes: 16,
      ),
    ];
    await tester.pumpWidget(
      CupertinoApp(
        home: AmbientContentSequence(
          repository: repository,
          items: items,
          interval: const Duration(seconds: 1),
          active: true,
          reducedMotion: false,
          renderer: (item, bytes, active, next) => Text('shown-${item.id[0]}'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('shown-b'), findsOneWidget);
    await tester.pumpWidget(
      CupertinoApp(
        home: AmbientContentSequence(
          repository: repository,
          items: items,
          interval: const Duration(seconds: 1),
          active: false,
          reducedMotion: false,
          renderer: (item, bytes, active, next) => const Text('late'),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('late'), findsNothing);
  });

  testWidgets(
    'reduced motion is forwarded and web policy is exact-origin only',
    (tester) async {
      final repository = _Repository();
      final item = AmbientContent.web(
        id: 'c' * 64,
        url: 'https://panel.example/status',
      );
      var reduced = false;
      await tester.pumpWidget(
        CupertinoApp(
          home: AmbientContentSequence(
            repository: repository,
            items: [item],
            interval: const Duration(seconds: 1),
            active: true,
            reducedMotion: true,
            renderer: (value, bytes, active, next) {
              reduced =
                  value.policy!.allows('https://panel.example/next') &&
                  !value.policy!.allows('https://evil.example/next');
              return const Text('web');
            },
          ),
        ),
      );
      await tester.pump();
      expect(reduced, isTrue);
    },
  );

  testWidgets('reduced motion keeps video static instead of autoplaying', (
    tester,
  ) async {
    final repository = _Repository();
    final item = AmbientContent.local(
      id: 'd' * 64,
      kind: AmbientContentKind.video,
      sizeBytes: 16,
    );
    await tester.pumpWidget(
      CupertinoApp(
        home: AmbientContentSequence(
          repository: repository,
          items: [item],
          interval: const Duration(seconds: 1),
          active: true,
          reducedMotion: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('ambient-video-reduced-motion')),
      findsOneWidget,
    );
  });

  testWidgets('late completion from previous item cannot skip current item', (
    tester,
  ) async {
    final repository = _Repository();
    final first = AmbientContent.web(
      id: 'e' * 64,
      url: 'https://panel.example/first',
    );
    final second = AmbientContent.web(
      id: 'f' * 64,
      url: 'https://panel.example/second',
    );
    VoidCallback? oldNext;
    await tester.pumpWidget(
      CupertinoApp(
        home: AmbientContentSequence(
          repository: repository,
          items: [first, second],
          interval: const Duration(minutes: 1),
          active: true,
          reducedMotion: true,
          renderer: (item, bytes, active, next) {
            if (item == first) oldNext ??= next;
            return Text(item == first ? 'first' : 'second');
          },
        ),
      ),
    );
    await tester.pump();
    oldNext!();
    await tester.pump();
    expect(find.text('second'), findsOneWidget);
    oldNext!();
    await tester.pump();
    expect(find.text('second'), findsOneWidget);
  });

  testWidgets('callback from retired content generation cannot advance', (
    tester,
  ) async {
    final repository = _Repository();
    final first = AmbientContent.web(
      id: '1' * 64,
      url: 'https://panel.example/first',
    );
    final second = AmbientContent.web(
      id: '2' * 64,
      url: 'https://panel.example/second',
    );
    VoidCallback? previous;
    Widget surface(List<AmbientContent> items) => CupertinoApp(
      home: AmbientContentSequence(
        repository: repository,
        items: items,
        interval: const Duration(minutes: 1),
        active: true,
        reducedMotion: true,
        renderer: (item, bytes, active, next) {
          previous ??= next;
          return Text(item == first ? 'first' : 'second');
        },
      ),
    );
    await tester.pumpWidget(surface([first, second]));
    await tester.pump();
    final stale = previous!;
    await tester.pumpWidget(surface([first, second]));
    await tester.pump();
    stale();
    await tester.pump();
    expect(find.text('first'), findsOneWidget);
    expect(find.text('second'), findsNothing);
  });
}
