import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
import 'package:larenor/features/media/arr/presentation/sonarr_screen.dart';

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
  for(final point in ['http', 'field']) {
    testWidgets('pending recovery loses window permission during $point without later key effects', (tester) async {
      secure.values['sonarr_connection_pending_v1']='1';
      final (c,_)=await routinesHome('direct');
      final interaction=AppInteractionController(); addTearDown(interaction.dispose);
      final response=Completer<http.Response>(); var calls=0;
      final channel=TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      channel.setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), (call) async {
        final result=await secure.handle(call);
        if(point=='field' && call.method=='write' && (call.arguments as Map)['key']=='sonarr_base_url') interaction.setActive(false);
        return result;
      });
      await http.runWithClient(() async {
        await tester.pumpWidget(UncontrolledProviderScope(container:c,child:CupertinoApp(
          localizationsDelegates:AppLocalizations.localizationsDelegates,supportedLocales:AppLocalizations.supportedLocales,
          builder:(_,child)=>AppInteractionScope(controller:interaction,child:child!),home:const SonarrScreen(),
        ))); await settle(tester);
        final fields=find.byType(CupertinoTextFormFieldRow);
        await tester.enterText(fields.at(0),'https://new.invalid'); await tester.enterText(fields.at(1),'synthetic-new-key');
        secure.calls.clear();
        await tester.tap(find.widgetWithText(CupertinoButton,'Connect')); await settle(tester);
        expect(calls,1);
        if(point=='http') interaction.setActive(false);
        response.complete(http.Response('{}',200)); await settle(tester);
        expect(secure.values['sonarr_api_key'],'synthetic-old-key');
        expect(secure.values['sonarr_connection_pending_v1'],'1');
        if(point=='http') expect(secure.calls.where((call)=>call.$1!='read'),isEmpty);
        expect(tester.takeException(),isNull);
        await tester.pumpWidget(const SizedBox.shrink());c.dispose();await settle(tester);
      },()=>MockClient((request) {calls++; return response.future;}));
    });
  }
  for(final name in arrServices) {
   for(final action in ['view','clear','connect']) {
    testWidgets('$name pending seed PIN route supports explicit $action without old prefill', (tester) async {
      var requests=0;
      await http.runWithClient(() async {
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
      if(action=='clear') {
        await tap(tester,'Remove saved connection');
        expect(secure.values.containsKey('${name}_connection_pending_v1'),isFalse);
        expect(secure.values.containsKey('${name}_base_url'),isFalse);
        expect(secure.values.containsKey('${name}_api_key'),isFalse);
        expect(find.text('Done'),findsOneWidget);
        expect(find.byType(LanDiscoverySection),findsNothing);
        expect(tester.widgetList<CupertinoTextFormFieldRow>(find.byType(CupertinoTextFormFieldRow)).map((f)=>f.controller!.text),everyElement(isEmpty));
        expect(requests,0);
      } else if(action=='connect') {
        await tester.enterText(find.byType(CupertinoTextFormFieldRow).at(0),'https://new.invalid');
        await tester.enterText(find.byType(CupertinoTextFormFieldRow).at(1),'synthetic-new-key');
        await tap(tester,'Connect');
        expect(secure.values['${name}_base_url'],'https://new.invalid');
        expect(secure.values['${name}_api_key'],'synthetic-new-key');
        expect(secure.values.containsKey('${name}_connection_pending_v1'),isFalse);
        expect(find.byType(ArrConnectForm),findsNothing);
        expect(requests,greaterThanOrEqualTo(1));
      } else { expect(requests,0); }

      expect(tester.takeException(),isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose(); // Dispose its health clock before widget-test timer checks.
      await settle(tester);
      },()=>MockClient((request) async {
        requests++;
        expect(request.url.host,'new.invalid');
        final body=request.url.path.endsWith('/queue') ? '{"records":[]}' : request.url.path.endsWith('/calendar') ? '[]' : '{}';
        return http.Response(body,200);
      }));
    });
   }
  }
}
