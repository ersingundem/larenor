import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/media/data/media_api_exception.dart';
import 'package:larenor/features/media/jellyseerr/data/jellyseerr_client.dart';
import 'package:larenor/features/media/jellyseerr/data/jellyseerr_config.dart';
import 'package:larenor/features/media/jellyseerr/data/models/jellyseerr_result.dart';
import 'package:larenor/features/media/jellyseerr/presentation/jellyseerr_home_screen.dart';
import 'package:larenor/features/media/jellyseerr/providers/jellyseerr_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

const _a = JellyseerrConfig(
  baseUrl: 'http://fixture.invalid',
  apiKey: 'fixture',
);

class _Connection extends JellyseerrConnection {
  @override
  Future<JellyseerrConfig?> build() async => _a;
  void change(AsyncValue<JellyseerrConfig?> value) => state = value;
}

class _Client extends JellyseerrClient {
  _Client() : super(config: _a);
  int writes = 0;
  Object? writeError, readError;
  Completer<void>? pendingWrite;
  Future<List<JellyseerrResult>> Function(String)? lookup;
  @override
  Future<List<JellyseerrResult>> search(String query) async {
    if (readError != null) throw readError!;
    return lookup?.call(query) ??
        [
          const JellyseerrResult(
            id: 42,
            mediaType: 'movie',
            title: 'Fixture movie',
          ),
        ];
  }

  @override
  Future<void> requestMedia({
    required String mediaType,
    required int mediaId,
    List<int>? seasons,
  }) async {
    writes++;
    await pendingWrite?.future;
    if (writeError != null) throw writeError!;
  }
}

class _Harness {
  final connection = _Connection();
  final client = _Client();
  final interaction = AppInteractionController();
  late ProviderContainer container;
  Future<void> mount(
    WidgetTester tester, {
    Size? size,
    double scale = 1,
  }) async {
    if (size != null) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }
    container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        jellyseerrConnectionProvider.overrideWith(() => connection),
        jellyseerrClientProvider.overrideWithValue(client),
        jellyseerrMyRequestsProvider.overrideWith((ref) async => []),
      ],
    );
    addTearDown(() {
      container.dispose();
      client.dispose();
      interaction.dispose();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: CupertinoApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => AppInteractionScope(
            controller: interaction,
            child: MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
          ),
          home: const JellyseerrHomeScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> search(WidgetTester tester, [String query = 'fixture']) async {
    tester
        .widget<CupertinoSearchTextField>(find.byType(CupertinoSearchTextField))
        .onSubmitted!(query);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  VoidCallback request(WidgetTester tester) => tester
      .widget<CupertinoButton>(find.widgetWithText(CupertinoButton, 'Request'))
      .onPressed!;
}

void main() {
  for (final cause in [
    'account',
    'loading',
    'error',
    'idle',
    'background',
    'covered',
  ]) {
    testWidgets('legacy request after $cause is rejected before server write', (
      tester,
    ) async {
      final h = _Harness();
      await h.mount(tester);
      await h.search(tester);
      final old = h.request(tester);
      switch (cause) {
        case 'account':
          h.connection.change(
            const AsyncData(
              JellyseerrConfig(
                baseUrl: 'http://other.invalid',
                apiKey: 'other',
              ),
            ),
          );
        case 'loading':
          h.connection.change(const AsyncLoading());
        case 'error':
          h.connection.change(
            const AsyncError('private-response', StackTrace.empty),
          );
        case 'idle':
          h.interaction.setActive(false);
        case 'background':
          for (final state in [
            AppLifecycleState.inactive,
            AppLifecycleState.hidden,
            AppLifecycleState.paused,
          ]) {
            tester.binding.handleAppLifecycleStateChanged(state);
          }
        case 'covered':
          Navigator.of(tester.element(find.byType(JellyseerrHomeScreen))).push(
            CupertinoPageRoute<void>(
              builder: (_) => const CupertinoPageScaffold(child: Text('Cover')),
            ),
          );
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      if (cause == 'idle') h.interaction.setActive(true);
      if (cause == 'background') {
        for (final state in [
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
      }
      old();
      await tester.pump();
      expect(h.client.writes, 0);
      expect(find.textContaining('private-response'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  }
  testWidgets('two callbacks send once and display accepted, never confirmed', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester);
    await h.search(tester);
    h.client.pendingWrite = Completer();
    final action = h.request(tester);
    action();
    action();
    await tester.pump();
    expect(h.client.writes, 1);
    h.client.pendingWrite!.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('accepted'), findsOneWidget);
    expect(find.text('Request'), findsNothing);
  });
  testWidgets('uncertain result stays blocked after idle and another search', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester);
    await h.search(tester);
    h.client.writeError = TimeoutException('private-url');
    h.request(tester)();
    await tester.pumpAndSettle();
    expect(find.textContaining('result is not confirmed'), findsOneWidget);
    expect(find.textContaining('private-url'), findsNothing);
    h.interaction.setActive(false);
    await tester.pump();
    h.interaction.setActive(true);
    await tester.pump();
    await h.search(tester);
    expect(find.text('Request'), findsNothing);
    expect(find.textContaining('result is not confirmed'), findsOneWidget);
    expect(h.client.writes, 1);
  });
  testWidgets('out-of-order query completion and captured old row do not act', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester);
    await h.search(tester);
    final action = h.request(tester);
    final old = Completer<List<JellyseerrResult>>();
    h.client.lookup = (q) async => q == 'old'
        ? old.future
        : [const JellyseerrResult(id: 99, mediaType: 'tv', name: 'Latest')];
    await h.search(tester, 'old');
    await h.search(tester, 'latest');
    old.complete([
      const JellyseerrResult(id: 10, mediaType: 'movie', title: 'Obsolete'),
    ]);
    await tester.pumpAndSettle();
    action();
    await tester.pump();
    expect(h.client.writes, 0);
    expect(find.text('Latest'), findsOneWidget);
    expect(find.text('Obsolete'), findsNothing);
  });
  for (final status in [401, 403]) {
    testWidgets('read $status displays safe failure rather than empty search', (
      tester,
    ) async {
      final h = _Harness();
      await h.mount(tester);
      h.client.readError = MediaApiException(
        'private-secret',
        statusCode: status,
      );
      await h.search(tester);
      await tester.pumpAndSettle();
      final l10n = AppLocalizations.of(
        tester.element(find.byType(JellyseerrHomeScreen)),
      );
      expect(
        find.text(
          status == 401
              ? l10n.healthAuthenticationRequired
              : l10n.healthPermissionDenied,
        ),
        findsOneWidget,
      );
      expect(find.textContaining('private-secret'), findsNothing);
    });
  }
  for (final size in [const Size(320, 700), const Size(1100, 900)]) {
    testWidgets('uncertain receipt fits $size at large text', (tester) async {
      final h = _Harness();
      await h.mount(tester, size: size, scale: 2);
      await h.search(tester);
      h.client.writeError = TimeoutException('fixture');
      h.request(tester)();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
