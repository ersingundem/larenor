import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/features/media/jellyfin/presentation/jellyfin_home_screen.dart';
import 'package:larenor/features/settings/data/app_service.dart';
import 'package:larenor/features/settings/presentation/manage_integrations_screen.dart';
import 'package:larenor/features/settings/providers/enabled_services_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/app_page_scaffold.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Enabled extends EnabledServices {
  _Enabled(this.load, {this.onSet});

  final Future<Set<AppService>> Function() load;
  final Future<void> Function(AppService service, bool enabled)? onSet;

  @override
  Future<Set<AppService>> build() => load();

  @override
  Future<void> setEnabled(AppService service, bool enabled) =>
      onSet?.call(service, enabled) ?? super.setEnabled(service, enabled);
}

Future<void> _mount(
  WidgetTester tester, {
  required EnabledServices Function() createEnabled,
  required Locale locale,
  required double width,
  double textScale = 2,
  bool settle = true,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [enabledServicesProvider.overrideWith(createEnabled)],
      child: CupertinoApp(
        theme: larenorTheme(brightness: Brightness.light),
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const ManageIntegrationsScreen(),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'enabled_services_migrated': true});
    FlutterSecureStorage.setMockInitialValues({});
  });

  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in [600.0, 1280.0]) {
      testWidgets(
        'service rows share tablet chrome, focus and semantics $locale $width',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            await _mount(
              tester,
              createEnabled: () => _Enabled(
                () async => {AppService.jellyfin, AppService.keenetic},
              ),
              locale: locale,
              width: width,
            );

            expect(find.byType(AppPageScaffold), findsOneWidget);
            final open = find.byKey(
              const ValueKey('integration-open-jellyfin'),
            );
            final toggle = find.byKey(
              const ValueKey('integration-toggle-jellyfin'),
            );
            expect(open, findsOneWidget);
            expect(toggle, findsOneWidget);

            final openNode = tester.getSemantics(open);
            expect(openNode.flagsCollection.isButton, isTrue);
            expect(openNode.rect.height, greaterThanOrEqualTo(48));
            expect(openNode.label, contains('Jellyfin'));

            final toggleNode = tester.getSemantics(toggle);
            expect(toggleNode.flagsCollection.isEnabled, ui.Tristate.isTrue);
            expect(toggleNode.flagsCollection.isToggled, ui.Tristate.isTrue);
            expect(toggleNode.rect.height, greaterThanOrEqualTo(48));
            expect(toggleNode.label, contains('Jellyfin'));

            final openLabel = find.descendant(
              of: open,
              matching: find.text('Jellyfin'),
            );
            Focus.of(tester.element(openLabel)).requestFocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.pump();
            expect(
              FocusManager.instance.primaryFocus!.context!
                  .findAncestorWidgetOfExactType<CupertinoSwitch>(),
              isNotNull,
            );

            await tester.scrollUntilVisible(
              find.byKey(const ValueKey('integration-open-keenetic')),
              300,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }

  testWidgets('loading never renders a false disabled service state', (
    tester,
  ) async {
    final pending = Completer<Set<AppService>>();
    await _mount(
      tester,
      createEnabled: () => _Enabled(() => pending.future),
      locale: const Locale('en'),
      width: 600,
      settle: false,
    );

    expect(find.text('Loading…'), findsOneWidget);
    expect(find.byType(CupertinoSwitch), findsNothing);

    pending.complete({AppService.jellyfin});
    await tester.pumpAndSettle();
    expect(find.text('Loading…'), findsNothing);
    expect(
      tester
          .getSemantics(
            find.byKey(const ValueKey('integration-toggle-jellyfin')),
          )
          .flagsCollection
          .isToggled,
      ui.Tristate.isTrue,
    );
  });

  testWidgets('load failure is recoverable and keeps private errors hidden', (
    tester,
  ) async {
    var attempts = 0;
    await _mount(
      tester,
      createEnabled: () => _Enabled(() async {
        attempts++;
        if (attempts == 1) {
          throw StateError('private storage path');
        }
        return {AppService.proxmox};
      }),
      locale: const Locale('en'),
      width: 600,
    );

    expect(find.text('Error'), findsOneWidget);
    expect(
      find.text('Integration choices could not be loaded.'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsOneWidget);
    expect(find.textContaining('private storage'), findsNothing);
    expect(find.byType(CupertinoSwitch), findsNothing);

    await tester.tap(find.widgetWithText(CupertinoButton, 'Retry'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('Error'), findsNothing);
    expect(
      tester
          .getSemantics(
            find.byKey(const ValueKey('integration-toggle-proxmox')),
          )
          .flagsCollection
          .isToggled,
      ui.Tristate.isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('navigation and switch are two explicit named actions', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await _mount(
        tester,
        createEnabled: () => _Enabled(() async => {AppService.jellyfin}),
        locale: const Locale('en'),
        width: 600,
        textScale: 1,
      );

      final open = tester.getSemantics(
        find.byKey(const ValueKey('integration-open-jellyfin')),
      );
      final toggle = tester.getSemantics(
        find.byKey(const ValueKey('integration-toggle-jellyfin')),
      );
      expect(open.getSemanticsData().hasAction(ui.SemanticsAction.tap), isTrue);
      expect(
        toggle.getSemanticsData().hasAction(ui.SemanticsAction.tap),
        isTrue,
      );
      expect(open.label, contains('Jellyfin'));
      expect(toggle.label, contains('Jellyfin'));
      expect(open.id, isNot(toggle.id));
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('Enter opens the actual service without changing its toggle', (
    tester,
  ) async {
    var writes = 0;
    await _mount(
      tester,
      createEnabled: () => _Enabled(
        () async => {AppService.jellyfin},
        onSet: (_, _) async => writes++,
      ),
      locale: const Locale('en'),
      width: 600,
      textScale: 1,
    );

    final open = find.byKey(const ValueKey('integration-open-jellyfin'));
    final openLabel = find.descendant(
      of: open,
      matching: find.text('Jellyfin'),
    );
    Focus.of(tester.element(openLabel)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.byType(JellyfinHomeScreen), findsOneWidget);
    expect(writes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed toggle keeps the prior state and hides private errors', (
    tester,
  ) async {
    await _mount(
      tester,
      createEnabled: () => _Enabled(
        () async => {AppService.jellyfin},
        onSet: (_, _) async => throw StateError('private write failure'),
      ),
      locale: const Locale('en'),
      width: 600,
      textScale: 1,
    );

    final toggle = find.byKey(const ValueKey('integration-toggle-jellyfin'));
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(
      find.text(
        'The integration choice could not be saved. '
        'Your previous setting remains in use.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('private write'), findsNothing);
    expect(
      tester.getSemantics(toggle).flagsCollection.isToggled,
      ui.Tristate.isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending toggle keeps one disabled named control in place', (
    tester,
  ) async {
    final pending = Completer<void>();
    var writes = 0;
    await _mount(
      tester,
      createEnabled: () => _Enabled(
        () async => {AppService.jellyfin},
        onSet: (_, _) {
          writes++;
          return pending.future;
        },
      ),
      locale: const Locale('en'),
      width: 600,
      textScale: 1,
    );

    final toggle = find.byKey(const ValueKey('integration-toggle-jellyfin'));
    await tester.tap(toggle);
    await tester.pump();

    expect(toggle, findsOneWidget);
    expect(
      tester.getSemantics(toggle).flagsCollection.isEnabled,
      ui.Tristate.isFalse,
    );
    expect(
      find.descendant(
        of: toggle,
        matching: find.byType(CupertinoActivityIndicator),
      ),
      findsOneWidget,
    );
    await tester.tap(toggle);
    await tester.pump();
    expect(writes, 1);

    pending.complete();
    await tester.pumpAndSettle();
    expect(toggle, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('every visible service action opens a real destination route', (
    tester,
  ) async {
    await _mount(
      tester,
      createEnabled: () => _Enabled(() async => AppService.values.toSet()),
      locale: const Locale('en'),
      width: 600,
      textScale: 1,
    );
    final navigator = Navigator.of(
      tester.element(find.byType(ManageIntegrationsScreen)),
    );

    for (final service in AppService.values) {
      final action = find.byKey(ValueKey('integration-open-${service.name}'));
      await tester.scrollUntilVisible(
        action,
        280,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(action);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(navigator.canPop(), isTrue, reason: service.name);
      navigator.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull, reason: service.name);
    }
  });
}
