import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/media/arr/presentation/widgets/arr_connect_form.dart';
import 'package:larenor/features/settings/presentation/settings_gate_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/discovery/lan_discovery_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/direct_arr_credentials_test.dart';
import '../../../core/direct_home_routines_test.dart' show routinesHome;

Future<void> settle(WidgetTester tester) async {
  for (var i=0;i<8;i++) { await tester.pump(const Duration(milliseconds:100)); }
}
Future<void> tap(WidgetTester tester, String title) async {
  final finder = find.text(title);
  await tester.ensureVisible(finder.first); await tester.tap(finder.first); await settle(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ArrSecurePlatform secure;
  late FlutterSecureStoragePlatform previous;
  setUp(() {
    secure = ArrSecurePlatform();
    secure.values['settings_pin'] = '2468';
    previous = FlutterSecureStoragePlatform.instance;
    FlutterSecureStoragePlatform.instance = MethodChannelFlutterSecureStorage();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), secure.handle,
    );
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() {
    FlutterSecureStoragePlatform.instance = previous;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), null,
    );
  });
  for(final name in arrServices) {
    testWidgets('$name pending seed still has PIN settings route to blank explicit recovery', (tester) async {
      secure.values['${name}_connection_pending_v1'] = '1';
      final (container, _) = await routinesHome('direct');
      final interaction = AppInteractionController(); addTearDown(interaction.dispose);
      tester.view.physicalSize = const Size(500,1000); tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(UncontrolledProviderScope(container:container, child: CupertinoApp(
        locale:const Locale('en'), localizationsDelegates:AppLocalizations.localizationsDelegates,
        supportedLocales:AppLocalizations.supportedLocales,
        builder:(_,child)=>AppInteractionScope(controller:interaction, child:child!),
        home:const SettingsGateScreen(),
      )));
      await settle(tester);
      expect(find.byType(ArrConnectForm),findsNothing);
      await tester.enterText(find.byType(CupertinoTextField),'2468');
      await tap(tester,'Unlock');
      await tap(tester,'Integrations');
      await tap(tester,'Manage Integrations');
      await tap(tester,'${name[0].toUpperCase()}${name.substring(1)}');
      expect(find.byType(ArrConnectForm),findsOneWidget);
      expect(find.byType(LanDiscoverySection),findsNothing);
      final fields = tester.widgetList<CupertinoTextFormFieldRow>(find.byType(CupertinoTextFormFieldRow));
      expect(fields,hasLength(2));
      expect(fields.map((field)=>field.controller!.text),everyElement(isEmpty));
      expect(find.textContaining('https://old.invalid'),findsNothing);
      expect(find.textContaining('synthetic-old-key'),findsNothing);
      expect(secure.values['${name}_connection_pending_v1'],'1');
      expect(tester.takeException(),isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose(); // Dispose its health clock before widget-test timer checks.
      await settle(tester);
    });
  }
}
