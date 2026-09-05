import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/media/arr/data/arr_client.dart';
import 'package:larenor/features/media/arr/data/arr_config.dart';
import 'package:larenor/features/media/arr/data/models/arr_lookup_result.dart';
import 'package:larenor/features/media/arr/data/models/arr_picker_options.dart';
import 'package:larenor/features/media/arr/presentation/radarr_screen.dart';
import 'package:larenor/features/media/arr/presentation/sonarr_screen.dart';
import 'package:larenor/features/media/arr/presentation/lidarr_screen.dart';
import 'package:larenor/features/media/arr/presentation/readarr_screen.dart';
import 'package:larenor/features/media/arr/providers/radarr_providers.dart';
import 'package:larenor/features/media/arr/providers/sonarr_providers.dart';
import 'package:larenor/features/media/arr/providers/lidarr_providers.dart';
import 'package:larenor/features/media/arr/providers/readarr_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

const _a = ArrConfig(baseUrl: 'http://fixture.invalid', apiKey: 'fixture-a');
const _b = ArrConfig(baseUrl: 'http://other.invalid', apiKey: 'fixture-b');

class _Radarr extends RadarrConnection {
  @override
  Future<ArrConfig?> build() async => _a;
  void change(AsyncValue<ArrConfig?> value) => state = value;
}

class _Sonarr extends SonarrConnection {
  @override
  Future<ArrConfig?> build() async => _a;
  void change(AsyncValue<ArrConfig?> value) => state = value;
}

class _Lidarr extends LidarrConnection {
  @override
  Future<ArrConfig?> build() async => _a;
  void change(AsyncValue<ArrConfig?> value) => state = value;
}

class _Readarr extends ReadarrConnection {
  @override
  Future<ArrConfig?> build() async => _a;
  void change(AsyncValue<ArrConfig?> value) => state = value;
}

ArrLookupResult _result(String name) => ArrLookupResult(
  title: name,
  remoteId: 42,
  raw: {'title': name, 'tmdbId': 42},
);

class _Client extends ArrClient {
  _Client() : super(config: _a, resourcePath: 'movie', idFieldName: 'tmdbId');
  int writes = 0, folderReads = 0;
  Object? failure;
  Completer<List<ArrQualityProfile>>? pendingProfiles;
  Future<List<ArrLookupResult>> Function(String)? search;
  @override
  Future<List<ArrLookupResult>> lookup(String term) async =>
      search?.call(term) ?? [_result('Source title')];
  @override
  Future<List<ArrQualityProfile>> getQualityProfiles() async =>
      pendingProfiles?.future ?? [const ArrQualityProfile(id: 3, name: 'HD')];
  @override
  Future<List<ArrRootFolder>> getRootFolders() async {
    folderReads++;
    return [const ArrRootFolder(id: 4, path: '/fixture-media')];
  }

  @override
  Future<List<ArrMetadataProfile>> getMetadataProfiles() async => [
    const ArrMetadataProfile(id: 5, name: 'Standard'),
  ];
  @override
  Future<void> add({
    required ArrLookupResult result,
    required int qualityProfileId,
    required String rootFolderPath,
    int? metadataProfileId,
    bool searchOnAdd = true,
  }) async {
    writes++;
    if (failure != null) throw failure!;
  }
}

class _Harness {
  final interaction = AppInteractionController();
  final client = _Client();
  late void Function(AsyncValue<ArrConfig?>) change;
  late ProviderContainer container;
  Future<void> mount(WidgetTester tester, String service) async {
    final r = _Radarr(), s = _Sonarr(), l = _Lidarr(), b = _Readarr();
    change = switch (service) {
      'sonarr' => s.change,
      'lidarr' => l.change,
      'readarr' => b.change,
      _ => r.change,
    };
    container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        radarrConnectionProvider.overrideWith(() => r),
        sonarrConnectionProvider.overrideWith(() => s),
        lidarrConnectionProvider.overrideWith(() => l),
        readarrConnectionProvider.overrideWith(() => b),
        radarrClientProvider.overrideWithValue(client),
        sonarrClientProvider.overrideWithValue(client),
        lidarrClientProvider.overrideWithValue(client),
        readarrClientProvider.overrideWithValue(client),
        radarrQueueProvider.overrideWith((ref) async => []),
        radarrCalendarProvider.overrideWith((ref) async => []),
        sonarrQueueProvider.overrideWith((ref) async => []),
        sonarrCalendarProvider.overrideWith((ref) async => []),
        lidarrQueueProvider.overrideWith((ref) async => []),
        lidarrCalendarProvider.overrideWith((ref) async => []),
        readarrQueueProvider.overrideWith((ref) async => []),
        readarrCalendarProvider.overrideWith((ref) async => []),
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
          builder: (context, child) =>
              AppInteractionScope(controller: interaction, child: child!),
          home: switch (service) {
            'sonarr' => const SonarrScreen(),
            'lidarr' => const LidarrScreen(),
            'readarr' => const ReadarrScreen(),
            _ => const RadarrScreen(),
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(CupertinoIcons.add));
    await tester.pumpAndSettle();
  }

  Future<void> search(WidgetTester tester, [String query = 'source']) async {
    tester
        .widget<CupertinoSearchTextField>(find.byType(CupertinoSearchTextField))
        .onSubmitted!(query);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<VoidCallback> confirm(WidgetTester tester) async {
    await search(tester);
    await tester.tap(find.text('Source title'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    return tester
        .widget<CupertinoActionSheetAction>(
          find.widgetWithText(CupertinoActionSheetAction, 'Add'),
        )
        .onPressed;
  }
}

void main() {
  for (final service in ['radarr', 'sonarr', 'lidarr', 'readarr']) {
    for (final cause in ['account', 'loading', 'error', 'idle', 'background']) {
      testWidgets('$service old add confirmation after $cause sends nothing', (
        tester,
      ) async {
        final h = _Harness();
        await h.mount(tester, service);
        final confirm = await h.confirm(tester);
        switch (cause) {
          case 'account':
            h.change(const AsyncData(_b));
          case 'loading':
            h.change(const AsyncLoading());
          case 'error':
            h.change(const AsyncError('private-body', StackTrace.empty));
          case 'idle':
            h.interaction.setActive(false);
          case 'background':
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.inactive,
            );
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.hidden,
            );
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.paused,
            );
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        if (cause == 'idle') h.interaction.setActive(true);
        if (cause == 'background') {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        }
        confirm();
        await tester.pump();
        expect(h.client.writes, 0);
        expect(find.textContaining('private-body'), findsNothing);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      });
    }
  }
  for (final service in ['radarr', 'sonarr', 'lidarr', 'readarr']) {
    testWidgets('$service fresh confirmation still adds once', (tester) async {
      final h = _Harness();
      await h.mount(tester, service);
      final confirm = await h.confirm(tester);
      confirm();
      await tester.pumpAndSettle();
      expect(h.client.writes, 1);
      expect(find.byType(CupertinoSearchTextField), findsNothing);
    });
  }
  testWidgets('unowned opaque cover invalidates pending profile reads', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester, 'radarr');
    h.client.pendingProfiles = Completer();
    await h.search(tester);
    await tester.tap(find.text('Source title'));
    await tester.pump();
    Navigator.of(tester.element(find.byType(CupertinoSearchTextField))).push(
      CupertinoPageRoute<void>(
        builder: (_) => const CupertinoPageScaffold(child: Text('Unrelated')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    h.client.pendingProfiles!.complete([
      const ArrQualityProfile(id: 1, name: 'Late'),
    ]);
    await tester.pumpAndSettle();
    expect(h.client.folderReads, 0);
    expect(find.byType(CupertinoActionSheet), findsNothing);
  });
  testWidgets('double confirmation sends exactly one add', (tester) async {
    final h = _Harness();
    await h.mount(tester, 'radarr');
    final confirm = await h.confirm(tester);
    confirm();
    confirm();
    await tester.pumpAndSettle();
    expect(h.client.writes, 1);
  });
  testWidgets('late profiles after idle do not read folders or reopen popup', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester, 'radarr');
    h.client.pendingProfiles = Completer();
    await h.search(tester);
    await tester.tap(find.text('Source title'));
    await tester.pump();
    h.interaction.setActive(false);
    await tester.pump();
    h.interaction.setActive(true);
    h.client.pendingProfiles!.complete([
      const ArrQualityProfile(id: 1, name: 'Late'),
    ]);
    await tester.pumpAndSettle();
    expect(h.client.folderReads, 0);
    expect(find.byType(CupertinoActionSheet), findsNothing);
  });
  testWidgets('older search completion cannot replace newest result', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester, 'radarr');
    final old = Completer<List<ArrLookupResult>>();
    h.client.search = (term) async =>
        term == 'old' ? old.future : [_result('Latest')];
    await h.search(tester, 'old');
    await h.search(tester, 'new');
    old.complete([_result('Obsolete')]);
    await tester.pumpAndSettle();
    expect(find.text('Latest'), findsOneWidget);
    expect(find.text('Obsolete'), findsNothing);
  });
  testWidgets(
    'uncertain add is visible and cannot be repeated on same screen',
    (tester) async {
      final h = _Harness();
      await h.mount(tester, 'radarr');
      h.client.failure = TimeoutException('private-endpoint');
      final confirm = await h.confirm(tester);
      confirm();
      await tester.pumpAndSettle();
      expect(h.client.writes, 1);
      expect(find.textContaining('result is not confirmed'), findsOneWidget);
      expect(find.textContaining('private-endpoint'), findsNothing);
      final row = tester.widget<CupertinoListTile>(
        find.widgetWithText(CupertinoListTile, 'Source title'),
      );
      expect(row.onTap, isNull);
    },
  );
}
