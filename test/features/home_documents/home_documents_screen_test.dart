import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/home_documents/data/home_document_controller.dart';
import 'package:larenor/features/home_documents/domain/home_document_models.dart';
import 'package:larenor/features/home_documents/presentation/home_documents_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import 'home_document_fixture.dart';

final class _ScreenGateway implements HomeDocumentGateway {
  _ScreenGateway({required this.pageValue, required this.reminderValue});
  final HomeDocumentPage pageValue;
  final HomeWarrantyReminderPage reminderValue;
  @override
  Future<HomeDocumentPage> search(String query) async => pageValue;
  @override
  Future<HomeDocumentReadback> readDocument(String documentId) async =>
      readback();
  @override
  Future<HomeWarrantyReminderPage> reminders(String today) async =>
      reminderValue;
  @override
  Future<HomeDocumentUploadEvidence?> pickAndUpload(
    String resourceId,
    int expectedAccountRevision,
  ) async => upload();
  @override
  Future<HomeDocumentCommandResult> create({
    required HomeDocumentPage base,
    required String requestId,
    required HomeDocumentDraft draft,
  }) => throw UnimplementedError();
  @override
  Future<HomeDocumentCommandResult> confirmWarranty({
    required HomeDocumentCommandResult created,
    required String requestId,
    required String confirmedDate,
  }) => throw UnimplementedError();
}

Future<HomeDocumentController> _mount(
  WidgetTester tester, {
  required Size size,
  required Locale locale,
  bool admin = true,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final controller = HomeDocumentController(
    gateway: _ScreenGateway(pageValue: page(), reminderValue: reminders()),
    context: context(),
    accountId: account,
    isAdmin: admin,
    isCurrent: () => true,
    requestIdFactory: () => 'b' * 32,
    documentIdFactory: () => document,
  );
  await controller.load();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    CupertinoApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: const TextScaler.linear(2),
        ),
        child: HomeDocumentsScreen(
          controller: controller,
          readers: [HomeDocumentReader(id: 'a' * 32, label: 'Ersin')],
          autoLoad: false,
        ),
      ),
    ),
  );
  await tester.pump();
  return controller;
}

void main() {
  for (final fixture in [
    (const Size(600, 1000), const Locale('tr'), 'Ev belgeleri'),
    (const Size(1200, 900), const Locale('en'), 'Home documents'),
  ]) {
    testWidgets(
      '${fixture.$1.width.toInt()}px ${fixture.$2.languageCode} at 2x keeps 48dp and TalkBack actions',
      (tester) async {
        await _mount(tester, size: fixture.$1, locale: fixture.$2);
        expect(find.text(fixture.$3), findsOneWidget);
        expect(find.text('Buzdolabı faturası'), findsOneWidget);
        expect(tester.takeException(), isNull);
        for (final key in [
          'home-doc-upload',
          'home-doc-resource',
          'home-doc-publish',
          'home-doc-refresh',
          'home-doc-kind-invoice',
        ]) {
          final target = tester.getSize(find.byKey(ValueKey(key)));
          expect(target.width, greaterThanOrEqualTo(48));
          expect(target.height, greaterThanOrEqualTo(48));
        }
        final semantics = tester.ensureSemantics();
        expect(
          tester.getSemantics(find.byKey(const ValueKey('home-doc-upload'))),
          matchesSemantics(
            label: fixture.$2.languageCode == 'tr'
                ? 'Belge seç ve yükle'
                : 'Choose and upload',
            isButton: true,
            hasEnabledState: true,
            isEnabled: true,
            hasTapAction: true,
          ),
        );
        semantics.dispose();
      },
    );
  }

  testWidgets(
    'member sees authorized private projection without admin actions',
    (tester) async {
      await _mount(
        tester,
        size: const Size(600, 1000),
        locale: const Locale('tr'),
        admin: false,
      );
      expect(find.text('Buzdolabı faturası'), findsOneWidget);
      expect(find.text('Özel belge'), findsOneWidget);
      expect(find.byKey(const ValueKey('home-doc-upload')), findsNothing);
      expect(find.byKey(const ValueKey('home-doc-publish')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('keyboard advances through explicit correction fields', (
    tester,
  ) async {
    await _mount(
      tester,
      size: const Size(600, 1000),
      locale: const Locale('en'),
    );
    await tester.tap(find.byKey(const ValueKey('home-doc-title')));
    await tester.enterText(
      find.byKey(const ValueKey('home-doc-title')),
      'Fridge invoice',
    );
    await tester.testTextInput.receiveAction(TextInputAction.next);
    expect(
      tester
          .widget<EditableText>(
            find.descendant(
              of: find.byKey(const ValueKey('home-doc-inventory')),
              matching: find.byType(EditableText),
            ),
          )
          .focusNode
          .hasFocus,
      isTrue,
    );
    await tester.enterText(
      find.byKey(const ValueKey('home-doc-inventory')),
      inventory,
    );
    await tester.testTextInput.receiveAction(TextInputAction.next);
    expect(
      tester
          .widget<EditableText>(
            find.descendant(
              of: find.byKey(const ValueKey('home-doc-warranty')),
              matching: find.byType(EditableText),
            ),
          )
          .focusNode
          .hasFocus,
      isTrue,
    );
  });
}
