import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/features/media/jellyseerr/data/jellyseerr_config.dart';
import 'package:larenor/features/media/jellyseerr/presentation/jellyseerr_home_screen.dart';
import 'package:larenor/features/media/jellyseerr/presentation/jellyseerr_requests_screen.dart';
import 'package:larenor/features/media/jellyseerr/providers/jellyseerr_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/app_page_scaffold.dart';
import 'package:larenor/shared/widgets/service_root_scaffold.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

class _FailingConnection extends JellyseerrConnection {
  _FailingConnection(this.onRead);

  final VoidCallback onRead;

  @override
  Future<JellyseerrConfig?> build() async {
    onRead();
    throw StateError('private upstream diagnostic');
  }
}

class _ConnectedConnection extends JellyseerrConnection {
  @override
  Future<JellyseerrConfig?> build() async => const JellyseerrConfig(
    baseUrl: 'https://jellyseerr.fixture.invalid',
    apiKey: 'fixture-key',
  );

  void change() => state = const AsyncData(
    JellyseerrConfig(
      baseUrl: 'https://replacement.fixture.invalid',
      apiKey: 'replacement-key',
    ),
  );
}

Future<void> _tabToRetry(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final button = FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<CupertinoButton>();
    if (button?.key == const ValueKey('jellyseerr-home-retry')) return;
  }
  fail('The Jellyseerr retry action is not reachable with Tab.');
}

void main() {
  testWidgets('captured retry cannot invalidate replacement connection', (
    tester,
  ) async {
    var reads = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          jellyseerrConnectionProvider.overrideWith(
            () => _FailingConnection(() => reads++),
          ),
        ],
        child: CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const JellyseerrHomeScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final retry = tester
        .widget<CupertinoButton>(
          find.byKey(const ValueKey('jellyseerr-home-retry')),
        )
        .onPressed!;
    final container = ProviderScope.containerOf(
      tester.element(find.byType(JellyseerrHomeScreen)),
    );
    container.invalidate(jellyseerrConnectionProvider);
    await tester.pumpAndSettle();
    expect(reads, 2);

    retry();
    await tester.pumpAndSettle();

    expect(reads, 2);
  });

  testWidgets('captured requests route cannot cross media account authority', (
    tester,
  ) async {
    final connection = _ConnectedConnection();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          jellyseerrConnectionProvider.overrideWith(() => connection),
          jellyseerrClientProvider.overrideWith((_) => null),
          jellyseerrMyRequestsProvider.overrideWith((_) async => []),
        ],
        child: CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const JellyseerrHomeScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final open = tester
        .widget<CupertinoButton>(
          find.byKey(const ValueKey('jellyseerr-requests-action')),
        )
        .onPressed!;

    connection.change();
    await tester.pumpAndSettle();
    open();
    await tester.pumpAndSettle();

    expect(find.byType(JellyseerrRequestsScreen), findsNothing);
  });

  for (final width in [600.0, 1200.0]) {
    testWidgets('Jellyseerr failure uses shared live tablet state and retry '
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
              jellyseerrConnectionProvider.overrideWith(
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
              home: const JellyseerrHomeScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final l10n = AppLocalizations.of(
          tester.element(find.byType(JellyseerrHomeScreen)),
        );

        expect(find.byType(AppSurface), findsOneWidget);
        expect(find.byType(ServiceRootScaffold), findsOneWidget);
        expect(find.byType(SettingsSection), findsOneWidget);
        expect(find.text(l10n.mediaErrorUnreachable), findsOneWidget);
        expect(
          find.textContaining('private upstream diagnostic'),
          findsNothing,
        );
        final status = tester.getSemantics(
          find.byKey(const ValueKey('jellyseerr-home-status')),
        );
        expect(status.label, l10n.mediaErrorUnreachable);
        expect(status.flagsCollection.isLiveRegion, isTrue);

        final retry = find.byKey(const ValueKey('jellyseerr-home-retry'));
        final retryNode = tester.getSemantics(retry);
        expect(retryNode.label, l10n.commonRetry);
        expect(retryNode.flagsCollection.isButton, isTrue);
        expect(retryNode.rect.height, greaterThanOrEqualTo(48));

        tester.view.physicalSize = Size(width == 600 ? 1200 : 600, 900);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('jellyseerr-home-status')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('jellyseerr-home-retry')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);

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

  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1200.0]) {
      testWidgets('${locale.languageCode} Jellyseerr hierarchy fits '
          '${width.toInt()}px at 2x text', (tester) async {
        final semantics = tester.ensureSemantics();
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        try {
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                jellyseerrConnectionProvider.overrideWith(
                  _ConnectedConnection.new,
                ),
                jellyseerrClientProvider.overrideWith((_) => null),
                jellyseerrMyRequestsProvider.overrideWith((_) async => []),
              ],
              child: CupertinoApp(
                theme: larenorTheme(),
                locale: locale,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: const TextScaler.linear(2)),
                  child: child!,
                ),
                home: const JellyseerrHomeScreen(),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final l10n = await AppLocalizations.delegate.load(locale);

          expect(find.byType(AppSurface), findsOneWidget);
          expect(find.byType(SettingsSection), findsOneWidget);
          final heading = find.text(l10n.mediaSearchTitle);
          final headingNode = tester.getSemantics(heading);
          expect(headingNode.flagsCollection.isHeader, isTrue);
          expect(headingNode.flagsCollection.isButton, isFalse);

          final search = find.byType(CupertinoSearchTextField);
          expect(tester.getRect(search).height, greaterThanOrEqualTo(48));
          final requestsAction = find.byKey(
            const ValueKey('jellyseerr-requests-action'),
          );
          expect(
            tester.getRect(requestsAction).height,
            greaterThanOrEqualTo(48),
          );
          final requestsNode = tester.getSemantics(requestsAction);
          expect(requestsNode.label, contains(l10n.jellyseerrMyRequestsTitle));
          expect(requestsNode.flagsCollection.isButton, isTrue);

          tester.view.physicalSize = Size(width == 600 ? 1200 : 600, 900);
          await tester.pumpAndSettle();
          expect(find.byType(SettingsSection), findsOneWidget);
          expect(
            find.byKey(const ValueKey('jellyseerr-requests-action')),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);

          Focus.of(tester.element(find.text(l10n.jellyseerrMyRequestsTitle)))
              .requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(find.byType(JellyseerrRequestsScreen), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });
    }
  }
}
