import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/media/arr/presentation/widgets/arr_connect_form.dart';
import 'package:larenor/features/media/data/media_api_exception.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/discovery/lan_discovery_section.dart';
import 'package:larenor/shared/discovery/service_signatures.dart';

import '../../../core/direct_home_routines_test.dart' show routinesHome;

Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final transition in [
    'idle',
    'background',
    'hidden',
    'route',
    'source',
    'callback',
    'disposed',
  ]) {
    testWidgets(
      'captured connect cannot outlive $transition even with a new draft',
      (tester) async {
        final (c, home) = await routinesHome('direct');
        final interaction = AppInteractionController();
        addTearDown(interaction.dispose);
        final navigator = GlobalKey<NavigatorState>();
        var calls = 0;
        Future<void> first(String _, String _, bool Function() _) async {
          calls++;
        }

        Future<void> second(String _, String _, bool Function() _) async {
          calls += 10;
        }

        var connect = first;
        var visible = true;
        Widget tree() => UncontrolledProviderScope(
          container: c,
          child: CupertinoApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            navigatorKey: navigator,
            builder: (_, child) =>
                AppInteractionScope(controller: interaction, child: child!),
            home: TickerMode(
              enabled: visible,
              child: ArrConnectForm(
                title: 'Sonarr',
                urlHint: '',
                onConnect: connect,
              ),
            ),
          ),
        );
        await tester.pumpWidget(tree());
        await frames(tester);
        Future<void> draft() async {
          final fields = find.byType(CupertinoTextFormFieldRow);
          await tester.enterText(fields.at(0), 'https://synthetic.invalid');
          await tester.enterText(fields.at(1), 'synthetic-key');
        }

        await draft();
        final button = find.widgetWithText(CupertinoButton, 'Connect');
        final old = tester.widget<CupertinoButton>(button).onPressed!;
        switch (transition) {
          case 'idle':
            interaction.setActive(false);
            await frames(tester);
            interaction.setActive(true);
            await frames(tester);
          case 'background':
            for (final state in [
              AppLifecycleState.inactive,
              AppLifecycleState.hidden,
              AppLifecycleState.paused,
              AppLifecycleState.hidden,
              AppLifecycleState.inactive,
              AppLifecycleState.resumed,
            ]) {
              tester.binding.handleAppLifecycleStateChanged(state);
              await frames(tester);
            }
          case 'hidden':
            visible = false;
            await tester.pumpWidget(tree());
            await frames(tester);
            visible = true;
            await tester.pumpWidget(tree());
            await frames(tester);
          case 'route':
            navigator.currentState!.push(
              CupertinoPageRoute<void>(
                builder: (_) =>
                    const CupertinoPageScaffold(child: Text('Covered')),
              ),
            );
            await frames(tester);
            navigator.currentState!.pop();
            await frames(tester);
          case 'source':
            await home.choose(HomeSource.verifiedCore);
            await frames(tester);
            await home.choose(HomeSource.directLocal);
            await frames(tester);
          case 'callback':
            connect = second;
            await tester.pumpWidget(tree());
            await frames(tester);
          case 'disposed':
            await tester.pumpWidget(const SizedBox.shrink());
            await frames(tester);
        }
        if (find.byType(CupertinoTextFormFieldRow).evaluate().isNotEmpty) {
          await draft();
        }
        old();
        await frames(tester);
        expect(calls, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        c.dispose();
        await frames(tester);
      },
    );
  }
  for (final failure in [false, true]) {
    testWidgets(
      'late ${failure ? "failure" : "success"} after form removal has no widget update',
      (tester) async {
        final (c, _) = await routinesHome('direct');
        final response = Completer<void>();
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: c,
            child: CupertinoApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: ArrConnectForm(
                title: 'Sonarr',
                urlHint: 'https://synthetic.invalid',
                onConnect: (_, _, _) => response.future,
              ),
            ),
          ),
        );
        await frames(tester);
        await tester.enterText(
          find.byType(CupertinoTextFormFieldRow).at(1),
          'synthetic-key',
        );
        await tester.tap(find.widgetWithText(CupertinoButton, 'Connect'));
        await tester.pump();
        await tester.pumpWidget(const SizedBox.shrink());
        if (failure) {
          response.completeError(MediaApiException('synthetic-error'));
        } else {
          response.complete();
        }
        await frames(tester);
        expect(tester.takeException(), isNull);
        c.dispose();
      },
    );
  }
  testWidgets(
    'cold Core connect form never mounts discovery or dispatches a callback',
    (tester) async {
      final (c, _) = await routinesHome('core');
      var calls = 0;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: CupertinoApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ArrConnectForm(
              title: 'Sonarr',
              urlHint: '',
              discoverySignature: ServiceSignatures.sonarr,
              onConnect: (_, _, _) async {
                calls++;
              },
            ),
          ),
        ),
      );
      await frames(tester);
      expect(find.byType(LanDiscoverySection), findsNothing);
      expect(find.byType(CupertinoTextFormFieldRow), findsNothing);
      expect(calls, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
      await frames(tester);
    },
  );
  for (final language in ['en', 'tr']) {
    for (final dark in [false, true]) {
      testWidgets(
        '$language recovery at 2x in ${dark ? "dark" : "light"} wraps with real fonts and reachable controls',
        (tester) async {
          await tester.runAsync(() async {
            final data = await rootBundle.load(
              'assets/fonts/Inter-Variable.ttf',
            );
            for (final family in [
              'Inter',
              'CupertinoSystemText',
              'CupertinoSystemDisplay',
            ]) {
              await (FontLoader(family)..addFont(Future.value(data))).load();
            }
          });
          tester.view.physicalSize = const Size(600, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final (c, _) = await routinesHome('direct');
          var clears = 0;
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: c,
              child: CupertinoApp(
                locale: Locale(language),
                theme: CupertinoThemeData(
                  brightness: dark ? Brightness.dark : Brightness.light,
                ),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(2)),
                  child: child!,
                ),
                home: ArrConnectForm(
                  title: 'Sonarr',
                  urlHint: '',
                  onConnect: (_, _, _) async {},
                  onClear: (current) async {
                    expect(current(), isTrue);
                    clears++;
                  },
                ),
              ),
            ),
          );
          await frames(tester);
          final l10n = AppLocalizations.of(
            tester.element(find.byType(ArrConnectForm)),
          );
          expect(find.text(l10n.arrConnectionIncomplete), findsOneWidget);
          final remove = find.widgetWithText(
            CupertinoButton,
            l10n.arrRemoveConnection,
          );
          await tester.ensureVisible(remove);
          await tester.tap(remove);
          await frames(tester);
          expect(clears, 1);
          expect(find.text(l10n.commonDone), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          c.dispose();
          await frames(tester);
        },
      );
    }
  }
  testWidgets(
    'empty or failed connect is static and a current explicit retry works',
    (tester) async {
      final (c, _) = await routinesHome('direct');
      var calls = 0;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: CupertinoApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ArrConnectForm(
              title: 'Sonarr',
              urlHint: '',
              onConnect: (url, key, current) async {
                expect(current(), isTrue);
                expect(url, 'https://synthetic.invalid');
                expect(key, 'synthetic');
                calls++;
                if (calls == 1) throw StateError('private-platform-error');
              },
            ),
          ),
        ),
      );
      await frames(tester);
      final connect = find.widgetWithText(CupertinoButton, 'Connect');
      await tester.tap(connect);
      await frames(tester);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(ArrConnectForm)),
      );
      expect(find.text(l10n.mediaErrorEnterUrlApiKey), findsOneWidget);
      expect(calls, 0);
      await tester.enterText(
        find.byType(CupertinoTextFormFieldRow).at(0),
        'https://synthetic.invalid/',
      );
      await tester.enterText(
        find.byType(CupertinoTextFormFieldRow).at(1),
        'synthetic',
      );
      await tester.tap(connect);
      await frames(tester);
      expect(calls, 1);
      expect(find.textContaining('private-platform'), findsNothing);
      expect(find.text(l10n.mediaErrorUnreachable), findsOneWidget);
      await tester.tap(connect);
      await frames(tester);
      expect(calls, 2);
      expect(find.text(l10n.mediaErrorUnreachable), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
      await frames(tester);
    },
  );
  testWidgets(
    'clear failure is static and old clear callback expires at idle',
    (tester) async {
      final (c, _) = await routinesHome('direct');
      final interaction = AppInteractionController();
      addTearDown(interaction.dispose);
      var clears = 0;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: CupertinoApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (_, child) =>
                AppInteractionScope(controller: interaction, child: child!),
            home: ArrConnectForm(
              title: 'Sonarr',
              urlHint: '',
              onConnect: (_, _, _) async {},
              onClear: (current) async {
                clears++;
                throw StateError('private-clear-error');
              },
            ),
          ),
        ),
      );
      await frames(tester);
      final remove = find.widgetWithText(
        CupertinoButton,
        'Remove saved connection',
      );
      await tester.ensureVisible(remove);
      final old = tester.widget<CupertinoButton>(remove).onPressed!;
      await tester.tap(remove);
      await frames(tester);
      expect(clears, 1);
      expect(find.textContaining('private-clear'), findsNothing);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(ArrConnectForm)),
      );
      expect(find.text(l10n.mediaErrorUnreachable), findsOneWidget);
      interaction.setActive(false);
      await frames(tester);
      interaction.setActive(true);
      await frames(tester);
      old();
      await frames(tester);
      expect(clears, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
      await frames(tester);
    },
  );
  testWidgets(
    'current keyboard Enter and Space activate named native actions',
    (tester) async {
      final (c, _) = await routinesHome('direct');
      var connects = 0, clears = 0;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: CupertinoApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ArrConnectForm(
              title: 'Sonarr',
              urlHint: 'https://synthetic.invalid',
              onConnect: (_, _, current) async {
                expect(current(), isTrue);
                connects++;
              },
              onClear: (current) async {
                expect(current(), isTrue);
                clears++;
              },
            ),
          ),
        ),
      );
      await frames(tester);
      await tester.enterText(
        find.byType(CupertinoTextFormFieldRow).at(1),
        'synthetic',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await frames(tester);
      expect(connects, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await frames(tester);
      expect(clears, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
      await frames(tester);
    },
  );
}
