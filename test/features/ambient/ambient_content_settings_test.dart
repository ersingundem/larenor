import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/ambient/data/ambient_content_repository.dart';
import 'package:larenor/features/ambient/domain/ambient_content.dart';
import 'package:larenor/features/ambient/presentation/ambient_content_settings.dart';
import 'package:larenor/features/ambient/providers/ambient_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

class _Repository implements AmbientContentRepositoryApi {
  @override
  Future<void> addWeb(String url, {required bool Function() isCurrent}) async {}
  @override
  Future<void> importLocal(
    AmbientContentKind kind,
    Stream<List<int>> source, {
    required bool Function() isCurrent,
  }) async {}
  @override
  Future<List<AmbientContent>> list() async => const [];
  @override
  Future<Uint8List> readLocal(AmbientContent item) =>
      throw UnimplementedError();
  @override
  Future<void> replaceOrder(
    List<AmbientContent> values, {
    required List<AmbientContent> expected,
    required bool Function() isCurrent,
  }) async {}
}

void main() {
  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1280.0]) {
      testWidgets(
        '${locale.languageCode} $width 2x content actions are accessible',
        (tester) async {
          final repository = _Repository();
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 1000);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            CupertinoApp(
              locale: locale,
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: const [
                AppLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: ProviderScope(
                overrides: [
                  ambientContentRepositoryProvider.overrideWithValue(
                    repository,
                  ),
                ],
                child: const CupertinoPageScaffold(
                  child: AmbientContentSettings(),
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 50));
          for (final key in const [
            'ambient-add-video',
            'ambient-add-pdf',
            'ambient-add-web',
          ]) {
            final action = find.byKey(ValueKey(key));
            expect(action, findsOneWidget);
            expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
            expect(
              tester
                  .getSemantics(action)
                  .getSemanticsData()
                  .flagsCollection
                  .isButton,
              isTrue,
            );
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('Tab and Enter open the explicit web permission dialog', (
    tester,
  ) async {
    await tester.pumpWidget(
      CupertinoApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: ProviderScope(
          overrides: [
            ambientContentRepositoryProvider.overrideWithValue(_Repository()),
          ],
          child: const CupertinoPageScaffold(child: AmbientContentSettings()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ambient-web-url')), findsOneWidget);
  });
}
