import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/service_root_scaffold.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Every service root screen was converted from a centred title to a large
/// one, which meant restructuring each body into slivers. These smoke
/// tests exist because that conversion is exactly the kind of change that
/// compiles fine and then throws at layout time.
Widget wrap(Widget child) => ProviderScope(
  child: CupertinoApp(
    theme: larenorTheme(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('ServiceRootScaffold', () {
    testWidgets('renders its title and slivers', (tester) async {
      await tester.pumpWidget(
        wrap(
          const ServiceRootScaffold(
            title: 'Proxmox VE',
            slivers: [SliverToBoxAdapter(child: Text('body content'))],
          ),
        ),
      );

      expect(find.text('Proxmox VE'), findsWidgets);
      expect(find.text('body content'), findsOneWidget);
    });

    testWidgets('uses a large title that lives inside the scroll view', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(const ServiceRootScaffold(title: 'Jellyfin', slivers: [])),
      );

      // A large title only collapses on scroll if it's a sliver, which is
      // the whole reason these screens were restructured.
      expect(find.byType(CupertinoSliverNavigationBar), findsOneWidget);
      expect(find.byType(CustomScrollView), findsOneWidget);
    });

    testWidgets('renders leading and trailing actions', (tester) async {
      await tester.pumpWidget(
        wrap(
          ServiceRootScaffold(
            title: 'qBittorrent',
            leading: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () {},
              child: const Icon(CupertinoIcons.refresh),
            ),
            trailing: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () {},
              child: const Icon(CupertinoIcons.add),
            ),
            slivers: const [],
          ),
        ),
      );

      expect(find.byIcon(CupertinoIcons.refresh), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.add), findsOneWidget);
    });

    testWidgets('lays out without overflowing at a large text scale', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          child: CupertinoApp(
            theme: larenorTheme(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: const ServiceRootScaffold(
                title: 'Keenetic',
                slivers: [
                  SliverToBoxAdapter(child: Text('a fairly long row label')),
                ],
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
    });
  });

  group('SliverFilledMessage', () {
    testWidgets('centres its child inside a scroll view', (tester) async {
      await tester.pumpWidget(
        wrap(
          const ServiceRootScaffold(
            title: 'Prowlarr',
            slivers: [SliverFilledMessage(child: Text('No indexers'))],
          ),
        ),
      );

      expect(find.text('No indexers'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
