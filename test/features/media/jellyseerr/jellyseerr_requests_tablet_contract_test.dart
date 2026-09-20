import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/features/media/jellyseerr/data/models/jellyseerr_request_item.dart';
import 'package:larenor/features/media/jellyseerr/presentation/jellyseerr_requests_screen.dart';
import 'package:larenor/features/media/jellyseerr/providers/jellyseerr_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/app_page_scaffold.dart';

const _request = JellyseerrRequestItem(
  id: 7,
  mediaType: 'movie',
  statusCode: 2,
  media: JellyseerrRequestMedia(title: 'Arrival'),
);

Future<void> _mount(
  WidgetTester tester, {
  required double width,
  required Future<List<JellyseerrRequestItem>> Function() read,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [jellyseerrMyRequestsProvider.overrideWith((ref) => read())],
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
        home: const JellyseerrRequestsScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tabToRefresh(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final button = FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<CupertinoButton>();
    if (button?.key == const ValueKey('jellyseerr-requests-refresh')) return;
  }
  fail('The Jellyseerr requests refresh action is not reachable with Tab.');
}

void main() {
  for (final width in [600.0, 1280.0]) {
    testWidgets('requests use shared tablet surface and keyboard refresh '
        '$width 2x', (tester) async {
      final semantics = tester.ensureSemantics();
      var reads = 0;
      try {
        await _mount(
          tester,
          width: width,
          read: () async {
            reads++;
            return const [_request];
          },
        );
        final l10n = AppLocalizations.of(
          tester.element(find.byType(JellyseerrRequestsScreen)),
        );

        expect(find.byType(AppSurface), findsOneWidget);
        final refresh = find.byKey(
          const ValueKey('jellyseerr-requests-refresh'),
        );
        final node = tester.getSemantics(refresh);
        expect(node.label, l10n.commonRefresh);
        expect(node.flagsCollection.isButton, isTrue);
        expect(node.rect.width, greaterThanOrEqualTo(48));
        expect(node.rect.height, greaterThanOrEqualTo(44));

        await _tabToRefresh(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(reads, 2);
        expect(find.text('Arrival'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('request failure is a private live status $width 2x', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        await _mount(
          tester,
          width: width,
          read: () async => throw StateError('private upstream diagnostic'),
        );
        final l10n = AppLocalizations.of(
          tester.element(find.byType(JellyseerrRequestsScreen)),
        );

        expect(find.text(l10n.mediaErrorUnreachable), findsOneWidget);
        expect(
          find.textContaining('private upstream diagnostic'),
          findsNothing,
        );
        final status = tester.getSemantics(
          find.byKey(const ValueKey('jellyseerr-requests-status')),
        );
        expect(status.label, l10n.mediaErrorUnreachable);
        expect(status.flagsCollection.isLiveRegion, isTrue);
        expect(find.byType(AppSurface), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }
}
