import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/admin/data/admin_client.dart';
import 'package:larenor/features/admin/data/models/ha_area.dart';
import 'package:larenor/features/admin/presentation/areas_screen.dart';
import 'package:larenor/features/admin/providers/admin_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/service_root_scaffold.dart';
import 'package:larenor/shared/widgets/settings_action_tile.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

import 'admin_test_fakes.dart';

Future<void> _mount(
  WidgetTester tester, {
  required String language,
  required double width,
  HaAdminClient? client,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        haAdminClientProvider.overrideWithValue(
          client ?? fakeAdminClient(RecordingAdminSocket()),
        ),
        areasProvider.overrideWith(
          (ref) async => const [HaArea(areaId: 'living', name: 'Living room')],
        ),
      ],
      child: CupertinoApp(
        locale: Locale(language),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: const AreasScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('captured add action cannot cross HA admin authority', (
    tester,
  ) async {
    final oldSocket = RecordingAdminSocket();
    final replacementSocket = RecordingAdminSocket();
    await _mount(
      tester,
      language: 'en',
      width: 600,
      client: fakeAdminClient(oldSocket),
    );
    final add = tester
        .widget<CupertinoButton>(
          find.ancestor(
            of: find.byIcon(CupertinoIcons.add),
            matching: find.byType(CupertinoButton),
          ),
        )
        .onPressed!;
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AreasScreen)),
    );
    container.updateOverrides([
      haAdminClientProvider.overrideWithValue(
        fakeAdminClient(replacementSocket),
      ),
      areasProvider.overrideWith(
        (ref) async => const [HaArea(areaId: 'living', name: 'Living room')],
      ),
    ]);
    await tester.pumpAndSettle();

    add();
    await tester.pumpAndSettle();

    expect(find.byType(CupertinoAlertDialog), findsNothing);
    expect(oldSocket.commands, isEmpty);
    expect(replacementSocket.commands, isEmpty);
  });

  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets('$language area action is accessible at ${width}px 2x', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        await _mount(tester, language: language, width: width);

        expect(find.byType(ServiceRootScaffold), findsOneWidget);
        expect(find.byType(SettingsSection), findsOneWidget);
        expect(find.byType(SettingsActionTile), findsOneWidget);
        final add = find.byKey(const ValueKey('areas-add'));
        final refresh = find.byKey(const ValueKey('areas-refresh'));
        expect(
          tester.getSemantics(add).label,
          AppLocalizations.of(tester.element(add)).adminAddArea,
        );
        expect(
          tester.getSemantics(refresh).label,
          AppLocalizations.of(tester.element(refresh)).commonRefresh,
        );
        expect(
          tester
              .getSemantics(find.byKey(const ValueKey('areas-list-header')))
              .flagsCollection
              .isHeader,
          isTrue,
        );

        final area = find.byKey(const ValueKey('admin-area-living'));
        expect(tester.getRect(area).height, greaterThanOrEqualTo(48));
        expect(tester.getSemantics(area).flagsCollection.isButton, isTrue);
        Focus.of(
          tester.element(
            find.descendant(of: area, matching: find.byType(Text)).first,
          ),
        ).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();

        expect(find.byType(CupertinoActionSheet), findsOneWidget);
        expect(tester.takeException(), isNull);
        semantics.dispose();
      });
    }
  }
}
