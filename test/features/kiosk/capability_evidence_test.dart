import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/kiosk/capability_evidence/domain/capability_evidence_models.dart';
import 'package:larenor/features/kiosk/capability_evidence/presentation/capability_evidence_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

Map<String, Object?> recordJson(String outcome) => {
  'schemaVersion': 1,
  'id': '0123456789abcdef0123456789abcdef',
  'revision': 2,
  'capabilityId': 'kiosk.window.lifecycle',
  'target': {
    'oem': 'Huawei',
    'model': 'MatePad 11.5 S 2026',
    'androidApi': 35,
    'webViewPackage': 'com.android.webview',
    'webViewVersion': '140.0.7339.51',
    'dexProfile': 'external_display',
    'permissions': ['android.permission.POST_NOTIFICATIONS'],
  },
  'outcome': outcome,
  'artifactName': 'k14-huawei-manual-gate.json',
  'artifactSha256': 'a' * 64,
  'sourceCommit': 'b' * 40,
  'testCase': 'manual.k14.huawei.window.lifecycle',
  'updatedAt': 1788609600.0,
};

void main() {
  test('strict model accepts only four outcomes and exact safe evidence links', () {
    for (final value in const ['tested', 'failed', 'untested', 'manual_required']) {
      expect(CapabilityEvidenceRecord.fromJson(recordJson(value)).outcome.name, value);
    }
    for (final value in ['passed', '', null, 1]) {
      expect(() => CapabilityEvidenceRecord.fromJson(recordJson(value as dynamic)), throwsFormatException);
    }
    for (final changes in [
      {'artifactName': '/tmp/private'},
      {'artifactName': 'https:evil.invalid'},
      {'sourceCommit': 'B' * 40},
      {'testCase': '../../secret'},
      {'secret': 'must-not-enter-contract'},
    ]) {
      expect(
        () => CapabilityEvidenceRecord.fromJson({...recordJson('untested'), ...changes}),
        throwsFormatException,
      );
    }
  });

  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1280.0]) {
      testWidgets('${locale.languageCode} $width 2x shows manual evidence without promotion', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 900);
        addTearDown(tester.view.reset);
        final controller = CapabilityEvidenceController(
          load: () async => [CapabilityEvidenceRecord.fromJson(recordJson('manual_required'))],
          current: () => true,
        );
        addTearDown(controller.dispose);
        await tester.pumpWidget(CupertinoApp(
          locale: locale,
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: CapabilityEvidenceScreen(controller: controller),
        ));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('capability-evidence-manual-required')), findsOneWidget);
        expect(find.text('Huawei'), findsOneWidget);
        expect(find.textContaining('k14-huawei'), findsOneWidget);
        final refresh = find.byKey(const ValueKey('capability-evidence-refresh'));
        expect(tester.getSize(refresh).height, greaterThanOrEqualTo(48));
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(controller.loadCount, 2);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('late response after authority loss is discarded and old proof is hidden', (tester) async {
    final pending = Completer<List<CapabilityEvidenceRecord>>();
    var current = true;
    final controller = CapabilityEvidenceController(load: () => pending.future, current: () => current);
    addTearDown(controller.dispose);
    await tester.pumpWidget(CupertinoApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: CapabilityEvidenceScreen(controller: controller),
    ));
    await tester.pump();
    current = false;
    controller.invalidate();
    pending.complete([CapabilityEvidenceRecord.fromJson(recordJson('tested'))]);
    await tester.pumpAndSettle();
    expect(find.text('Huawei'), findsNothing);
    expect(controller.records, isEmpty);
  });
}
