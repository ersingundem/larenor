import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/features/media/qbittorrent/data/qbittorrent_config.dart';
import 'package:larenor/features/media/qbittorrent/presentation/qbittorrent_torrents_screen.dart';
import 'package:larenor/features/media/qbittorrent/providers/qbittorrent_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/app_page_scaffold.dart';

import '../../../core/direct_home_routines_test.dart' show routinesHome;

const _config = QbittorrentConfig(
  baseUrl: 'http://qbittorrent.test',
  username: 'fixture',
  password: 'fixture',
);

class _FailingConnection extends QbittorrentConnection {
  _FailingConnection(this.onRead);
  final VoidCallback onRead;
  @override
  Future<QbittorrentConfig?> build() async {
    onRead();
    throw StateError('private qBittorrent diagnostic');
  }
}

class _ConnectedConnection extends QbittorrentConnection {
  @override
  Future<QbittorrentConfig?> build() async => _config;
}

Widget _app(Widget home) => CupertinoApp(
  theme: larenorTheme(),
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context)
        .copyWith(textScaler: const TextScaler.linear(2)),
    child: child!,
  ),
  home: home,
);

Future<void> _tabToRetry(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final button = FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<CupertinoButton>();
    if (button?.key == const ValueKey('qbittorrent-torrents-retry')) return;
  }
  fail('The qBittorrent route retry action is not reachable with Tab.');
}

void main() {
  for (final width in [600.0, 1280.0]) {
    testWidgets('qBittorrent root separates read failure from denied access '
        '$width 2x', (tester) async {
      final semantics = tester.ensureSemantics();
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      try {
        final (direct, _) = await routinesHome('direct');
        var reads = 0;
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: direct,
            child: ProviderScope(
              key: const ValueKey('qbittorrent-error-scope'),
              overrides: [
                qbittorrentConnectionProvider.overrideWith(
                  () => _FailingConnection(() => reads++),
                ),
              ],
              child: _app(const QbittorrentTorrentsScreen()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final l10n = AppLocalizations.of(
          tester.element(find.byType(QbittorrentTorrentsScreen)),
        );
        expect(find.byType(AppSurface), findsOneWidget);
        expect(find.text(l10n.mediaErrorUnreachable), findsOneWidget);
        expect(
          find.textContaining('private qBittorrent diagnostic'),
          findsNothing,
        );
        final failure = tester.getSemantics(
          find.byKey(const ValueKey('qbittorrent-torrents-status')),
        );
        expect(failure.label, l10n.mediaErrorUnreachable);
        expect(failure.flagsCollection.isLiveRegion, isTrue);
        final retry = tester.getSemantics(
          find.byKey(const ValueKey('qbittorrent-torrents-retry')),
        );
        expect(retry.label, l10n.commonRetry);
        expect(retry.flagsCollection.isButton, isTrue);
        expect(retry.rect.height, greaterThanOrEqualTo(48));
        await _tabToRetry(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(reads, 2);

        final (core, _) = await routinesHome('core');
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: core,
            child: ProviderScope(
              key: const ValueKey('qbittorrent-denied-scope'),
              overrides: [
                qbittorrentConnectionProvider.overrideWith(
                  _ConnectedConnection.new,
                ),
              ],
              child: _app(const QbittorrentTorrentsScreen()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AppSurface), findsOneWidget);
        expect(find.text(l10n.mediaAccountChanged), findsOneWidget);
        final denied = tester.getSemantics(
          find.byKey(const ValueKey('qbittorrent-torrents-status')),
        );
        expect(denied.label, l10n.mediaAccountChanged);
        expect(denied.flagsCollection.isLiveRegion, isTrue);
        expect(
          find.byKey(const ValueKey('qbittorrent-torrents-retry')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
      } finally {
        semantics.dispose();
      }
    });
  }
}
