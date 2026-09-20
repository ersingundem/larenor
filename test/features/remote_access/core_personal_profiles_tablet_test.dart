import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import 'core_personal_profiles_test_support.dart';
import 'remote_profiles_ui_fixture.dart';

void main() {
  for (final locale in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets(
        '$locale ${width.toInt()} 2x exposes local/Core sources and keyboard Core flow',
        (tester) async {
          final fixture = CoreProfilesFixture();
          await fixture.account.initialize();
          addTearDown(fixture.account.dispose);
          final ui = RemoteUi();
          await ui.mount(
            tester,
            width: width,
            scale: 2,
            locale: locale,
            serverAccount: fixture.account,
          );

          final source = key('remote-source-core-managed');
          expect(source, findsOneWidget);
          expect(tester.getRect(source).height, greaterThanOrEqualTo(48));
          final semantics = tester.getSemantics(source);
          expect(semantics.flagsCollection.isButton, isTrue);
          expect(
            semantics.label,
            contains(locale == 'en' ? 'Larenor Core' : 'Larenor Core'),
          );

          await press(tester, 'remote-source-core-managed');
          await tester.pumpAndSettle();
          expect(key('core-profile-$profileId'), findsOneWidget);
          expect(find.textContaining('synthetic_admin_access'), findsNothing);
          expect(find.textContaining('private-user'), findsNothing);

          final row = key('core-profile-$profileId');
          await tester.ensureVisible(row);
          final rowText = find
              .descendant(of: row, matching: find.byType(Text))
              .first;
          Focus.of(tester.element(rowText)).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(key('core-profile-name'), findsOneWidget);
          expect(tester.takeException(), isNull);

          final l = AppLocalizations.of(
            tester.element(key('core-profile-name')),
          );
          expect(find.text(l.remoteAccessCoreManaged), findsWidgets);
          await tester.ensureVisible(key('core-profile-user'));
          await tester.pumpAndSettle();
          await tester.tap(key('core-profile-user'));
          await tester.pump();
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(
            tester.getRect(key('core-profiles-back')).height,
            greaterThanOrEqualTo(48),
          );
        },
      );
    }
  }

  testWidgets(
    'conflict refresh rebinds the draft without automatic overwrite',
    (tester) async {
      final fixture = CoreProfilesFixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final ui = RemoteUi();
      await ui.mount(
        tester,
        width: 600,
        scale: 2,
        serverAccount: fixture.account,
      );
      await press(tester, 'remote-source-core-managed');
      await press(tester, 'core-profile-$profileId');
      await tester.enterText(key('core-profile-name'), 'My reviewed edit');
      fixture.record = profileJson(revision: 2, label: 'Other tablet edit');
      fixture.conflict = true;
      await press(tester, 'core-profile-save');
      expect(find.textContaining('changed on Core'), findsOneWidget);
      expect(fixture.record['label'], 'Other tablet edit');

      fixture.conflict = false;
      await press(tester, 'core-profiles-refresh');
      await press(tester, 'core-profile-save');
      expect(fixture.record['label'], 'My reviewed edit');
      expect(fixture.record['revision'], 3);
      expect(key('core-profile-name'), findsNothing);
    },
  );
}
