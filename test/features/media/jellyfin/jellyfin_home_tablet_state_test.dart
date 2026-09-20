import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_config.dart';
import 'package:larenor/features/media/jellyfin/presentation/jellyfin_home_screen.dart';
import 'package:larenor/features/media/jellyfin/providers/jellyfin_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/app_page_scaffold.dart';

class _FailingConnection extends JellyfinConnection {
  _FailingConnection(this.onRead);

  final VoidCallback onRead;

  @override
  Future<JellyfinConfig?> build() async {
    onRead();
    throw StateError('private upstream diagnostic');
  }
}

Future<void> _tabToRetry(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final button = FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<CupertinoButton>();
    if (button?.key == const ValueKey('jellyfin-home-retry')) return;
  }
  fail('The Jellyfin retry action is not reachable with Tab.');
}

void main() {
  for (final width in [600.0, 1280.0]) {
    testWidgets('Jellyfin failure uses shared live tablet state and retry '
        '$width 2x', (tester) async {
      final semantics = tester.ensureSemantics();
      var reads = 0;
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              jellyfinConnectionProvider.overrideWith(
                () => _FailingConnection(() => reads++),
              ),
            ],
            child: CupertinoApp(
              theme: larenorTheme(),
              locale: const Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: const JellyfinHomeScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final l10n = AppLocalizations.of(
          tester.element(find.byType(JellyfinHomeScreen)),
        );

        expect(find.byType(AppSurface), findsOneWidget);
        expect(find.text(l10n.mediaErrorUnreachable), findsOneWidget);
        expect(
          find.textContaining('private upstream diagnostic'),
          findsNothing,
        );
        final status = tester.getSemantics(
          find.byKey(const ValueKey('jellyfin-home-status')),
        );
        expect(status.label, l10n.mediaErrorUnreachable);
        expect(status.flagsCollection.isLiveRegion, isTrue);

        final retry = find.byKey(const ValueKey('jellyfin-home-retry'));
        final retryNode = tester.getSemantics(retry);
        expect(retryNode.label, l10n.commonRetry);
        expect(retryNode.flagsCollection.isButton, isTrue);
        expect(retryNode.rect.height, greaterThanOrEqualTo(48));

        await _tabToRetry(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(reads, 2);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }
}
