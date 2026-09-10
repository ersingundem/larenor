import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/settings/presentation/settings_gate_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
 testWidgets('personal remote targets are visible in tablet Settings without Core or Proxmox', (tester) async {
   SharedPreferences.setMockInitialValues({});
   FlutterSecureStorage.setMockInitialValues({});
   tester.view.physicalSize=const Size(1280,1000);tester.view.devicePixelRatio=1;
   addTearDown(tester.view.reset);
   await tester.pumpWidget(const ProviderScope(child:CupertinoApp(
     localizationsDelegates:AppLocalizations.localizationsDelegates,
     supportedLocales:AppLocalizations.supportedLocales,home:SettingsGateScreen())));
   await tester.pumpAndSettle();
   expect(find.text('Remote access'),findsOneWidget);
   await tester.tap(find.text('Remote access'));
   await tester.pumpAndSettle();
   expect(find.text('No saved remote targets'),findsOneWidget);
 });
}
