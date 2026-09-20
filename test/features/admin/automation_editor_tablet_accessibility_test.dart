import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/admin/presentation/automation_editor_screen.dart';
import 'package:larenor/features/admin/providers/admin_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/service_root_scaffold.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

import 'admin_test_fakes.dart';

Future<List<http.Request>> _mount(
  WidgetTester tester, {
  required String language,
  required double width,
  AutomationEditorScreen? screen,
  Future<http.Response> Function(http.Request request)? respond,
}) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final saved = <http.Request>[];
  final client = fakeAdminClient(
    RecordingAdminSocket(),
    respond: (request) async {
      saved.add(request);
      if (respond != null) return respond(request);
      return http.Response('{}', 200);
    },
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [haAdminClientProvider.overrideWithValue(client)],
      child: CupertinoApp(
        locale: Locale(language),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => CupertinoPageScaffold(
            child: Center(
              child: CupertinoButton(
                onPressed: () => Navigator.of(context).push(
                  CupertinoPageRoute<void>(
                    builder: (_) =>
                        screen ??
                        const AutomationEditorScreen(
                          initialConfig: {
                            'alias': 'Evening lights',
                            'triggers': [],
                            'conditions': [],
                            'actions': [],
                          },
                        ),
                  ),
                ),
                child: const Text('Open automation editor'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open automation editor'));
  await tester.pumpAndSettle();
  return saved;
}

void main() {
  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets(
        '$language automation editor is accessible at ${width}px 2x',
        (tester) async {
          final semantics = tester.ensureSemantics();
          final saved = await _mount(tester, language: language, width: width);

          expect(find.byType(ServiceRootScaffold), findsOneWidget);
          expect(find.byType(SettingsSection), findsOneWidget);
          expect(
            tester
                .getSemantics(
                  find.byKey(const ValueKey('automation-json-header')),
                )
                .flagsCollection
                .isHeader,
            isTrue,
          );

          final editor = find.byKey(const ValueKey('automation-json-editor'));
          expect(tester.getRect(editor).height, greaterThanOrEqualTo(320));
          expect(
            tester.getSemantics(editor).flagsCollection.isTextField,
            isTrue,
          );

          final save = find.byKey(const ValueKey('automation-save-action'));
          expect(tester.getSemantics(save).flagsCollection.isButton, isTrue);
          final saveButton = tester.widget<CupertinoButton>(
            find.descendant(of: save, matching: find.byType(CupertinoButton)),
          );
          expect(saveButton.minimumSize?.height, greaterThanOrEqualTo(48));
          expect(saveButton.minimumSize?.width, greaterThanOrEqualTo(48));

          Focus.of(
            tester.element(
              find.descendant(of: save, matching: find.byType(Text)),
            ),
          ).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();

          expect(saved, hasLength(1));
          expect(find.text('Open automation editor'), findsOneWidget);
          expect(tester.takeException(), isNull);
          semantics.dispose();
        },
      );
    }
  }

  testWidgets('invalid JSON stays local and announces an error', (
    tester,
  ) async {
    final saved = await _mount(tester, language: 'en', width: 600);
    await tester.enterText(
      find.byKey(const ValueKey('automation-json-editor')),
      '{',
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('automation-save-action')),
        matching: find.byType(CupertinoButton),
      ),
    );
    await tester.pump();

    expect(saved, isEmpty);
    expect(find.textContaining('JSON'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('existing automation loads and confirmed delete returns', (
    tester,
  ) async {
    final requests = await _mount(
      tester,
      language: 'en',
      width: 600,
      screen: const AutomationEditorScreen(automationId: 'evening'),
      respond: (request) async {
        if (request.method == 'GET') {
          return http.Response(
            '{"alias":"Evening lights","triggers":[],"conditions":[],"actions":[]}',
            200,
          );
        }
        return http.Response('{}', 200);
      },
    );

    expect(find.textContaining('Evening lights'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('automation-delete-action')),
        matching: find.byType(CupertinoButton),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(requests.map((request) => request.method), ['GET', 'DELETE']);
    expect(find.text('Open automation editor'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('load and save failures remain visible and recoverable', (
    tester,
  ) async {
    await _mount(
      tester,
      language: 'en',
      width: 600,
      screen: const AutomationEditorScreen(automationId: 'unavailable'),
      respond: (_) async => throw http.ClientException('offline'),
    );

    expect(
      find.byKey(const ValueKey('automation-error-message')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('automation-json-editor')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('captured save action expires after lifecycle return', (
    tester,
  ) async {
    final saved = await _mount(tester, language: 'en', width: 600);
    final old = tester
        .widget<CupertinoButton>(
          find.descendant(
            of: find.byKey(const ValueKey('automation-save-action')),
            matching: find.byType(CupertinoButton),
          ),
        )
        .onPressed!;
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    old();
    await tester.pumpAndSettle();
    expect(saved, isEmpty);
    expect(find.textContaining('app session changed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
