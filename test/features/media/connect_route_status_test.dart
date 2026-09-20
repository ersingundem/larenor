import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_config.dart';
import 'package:larenor/features/media/jellyfin/presentation/jellyfin_connect_screen.dart';
import 'package:larenor/features/media/jellyfin/providers/jellyfin_providers.dart';
import 'package:larenor/features/media/qbittorrent/data/qbittorrent_config.dart';
import 'package:larenor/features/media/qbittorrent/presentation/qbittorrent_connect_screen.dart';
import 'package:larenor/features/media/qbittorrent/providers/qbittorrent_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/app_page_scaffold.dart';

import '../../core/direct_home_routines_test.dart' show routinesHome;

class _JellyfinConnection extends JellyfinConnection {
  _JellyfinConnection(this.onRead);
  final VoidCallback onRead;
  @override
  Future<JellyfinConfig?> build() async {
    onRead();
    throw StateError('private Jellyfin diagnostic');
  }
}

class _QbittorrentConnection extends QbittorrentConnection {
  _QbittorrentConnection(this.onRead);
  final VoidCallback onRead;
  @override
  Future<QbittorrentConfig?> build() async {
    onRead();
    throw StateError('private qBittorrent diagnostic');
  }
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

Future<void> _tabTo(WidgetTester tester, Key key) async {
  for (var i = 0; i < 8; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final button = FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<CupertinoButton>();
    if (button?.key == key) return;
  }
  fail('The connect retry action is not reachable with Tab.');
}

void _expectState(
  WidgetTester tester, {
  required String statusKey,
  required String retryKey,
  required String privateDiagnostic,
}) {
  final l10n = AppLocalizations.of(tester.element(find.byType(AppSurface)));
  expect(find.byType(AppSurface), findsOneWidget);
  expect(find.text(l10n.mediaErrorUnreachable), findsOneWidget);
  expect(find.textContaining(privateDiagnostic), findsNothing);
  final status = tester.getSemantics(find.byKey(ValueKey(statusKey)));
  expect(status.label, l10n.mediaErrorUnreachable);
  expect(status.flagsCollection.isLiveRegion, isTrue);
  final retry = tester.getSemantics(find.byKey(ValueKey(retryKey)));
  expect(retry.label, l10n.commonRetry);
  expect(retry.flagsCollection.isButton, isTrue);
  expect(retry.rect.height, greaterThanOrEqualTo(48));
}

void main() {
  for (final width in [600.0, 1280.0]) {
    testWidgets('custom media connect routes share private recovery state '
        '$width 2x', (tester) async {
      final semantics = tester.ensureSemantics();
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (container, _) = await routinesHome('direct');
      try {
        var jellyfinReads = 0;
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: ProviderScope(
              key: const ValueKey('jellyfin-connect-scope'),
              overrides: [
                jellyfinConnectionProvider.overrideWith(
                  () => _JellyfinConnection(() => jellyfinReads++),
                ),
              ],
              child: _app(const JellyfinConnectScreen()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        _expectState(
          tester,
          statusKey: 'jellyfin-connect-status',
          retryKey: 'jellyfin-connect-retry',
          privateDiagnostic: 'private Jellyfin diagnostic',
        );
        await _tabTo(tester, const ValueKey('jellyfin-connect-retry'));
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(jellyfinReads, 2);

        var qbittorrentReads = 0;
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: ProviderScope(
              key: const ValueKey('qbittorrent-connect-scope'),
              overrides: [
                qbittorrentConnectionProvider.overrideWith(
                  () => _QbittorrentConnection(() => qbittorrentReads++),
                ),
              ],
              child: _app(const QbittorrentConnectScreen()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        _expectState(
          tester,
          statusKey: 'qbittorrent-connect-status',
          retryKey: 'qbittorrent-connect-retry',
          privateDiagnostic: 'private qBittorrent diagnostic',
        );
        await _tabTo(tester, const ValueKey('qbittorrent-connect-retry'));
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(qbittorrentReads, 2);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }
}
