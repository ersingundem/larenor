import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/core/window/window_policy_models.dart';
import 'package:larenor/core/window/window_policy_providers.dart';
import 'package:larenor/features/remote_access/data/remote_profiles.dart';
import 'package:larenor/features/settings/presentation/settings_gate_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

Finder key(String id) => find.byKey(ValueKey(id));
Future<void> press(WidgetTester t, String id) async {
  await t.ensureVisible(key(id));
  await t.pumpAndSettle();
  expect(key(id).hitTestable(), findsOneWidget);
  await t.tap(key(id));
  await t.pumpAndSettle();
}

VoidCallback held(WidgetTester t, String id) => t
    .widget<CupertinoButton>(
      find.descendant(of: key(id), matching: find.byType(CupertinoButton)),
    )
    .onPressed!;

class RemoteUi {
  final values = <String, String>{};
  final calls = <String>[];
  final interaction = AppInteractionController();
  final navigator = GlobalKey<NavigatorState>();
  final boundary = GlobalKey();
  final windows = StreamController<WindowPolicySnapshot>.broadcast(sync: true);
  String? clipboard;
  bool failWrite = false;
  Future<void> Function(String key)? afterRead;
  int get writes =>
      calls.where((c) => c == 'write:${RemoteProfilesStore.storageKey}').length;
  Future<void> mount(
    WidgetTester t, {
    double width = 600,
    double scale = 1,
    String locale = 'en',
    bool pin = false,
  }) async {
    SharedPreferences.setMockInitialValues({});
    if (pin) values['settings_pin'] = '1234';
    final previous = FlutterSecureStoragePlatform.instance;
    FlutterSecureStoragePlatform.instance = MethodChannelFlutterSecureStorage();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final a = Map<String, dynamic>.from(call.arguments as Map);
            final k = a['key'] as String?;
            calls.add('${call.method}:$k');
            switch (call.method) {
              case 'read':
                final value = values[k];
                await afterRead?.call(k!);
                return value;
              case 'write':
                values[k!] = a['value'] as String;
                if (failWrite && k == RemoteProfilesStore.storageKey) {
                  throw PlatformException(code: 'private');
                }
                return null;
              case 'delete':
                values.remove(k);
                return null;
              case 'containsKey':
                return values.containsKey(k);
              default:
                throw StateError('Unexpected secure method ${call.method}');
            }
          },
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
    addTearDown(() async {
      FlutterSecureStoragePlatform.instance = previous;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            null,
          );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
      await windows.close();
      interaction.dispose();
    });
    t.view.physicalSize = Size(width, 1100);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          windowPolicySnapshotProvider.overrideWith((ref) async* {
            yield const WindowPolicySnapshot();
            yield* windows.stream;
          }),
        ],
        child: CupertinoApp(
          navigatorKey: navigator,
          locale: Locale(locale),
          theme: larenorTheme(
            brightness: locale == 'tr' ? Brightness.dark : Brightness.light,
          ),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: AppInteractionScope(
              controller: interaction,
              child: RepaintBoundary(key: boundary, child: child!),
            ),
          ),
          home: const SettingsGateScreen(),
        ),
      ),
    );
    await t.pumpAndSettle();
    if (pin) {
      await t.enterText(find.byType(CupertinoTextField), '1234');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pumpAndSettle();
    }
    final title = locale == 'en' ? 'Remote access' : 'Uzak erişim';
    await t.ensureVisible(find.text(title));
    await t.pumpAndSettle();
    await t.tap(find.text(title));
    await t.pumpAndSettle();
  }

  Future<void> edit(
    WidgetTester t, {
    String host = 'nas.example',
    String name = 'NAS',
  }) async {
    await press(t, 'remote-add');
    await t.enterText(key('remote-name'), name);
    await t.enterText(key('remote-host'), host);
    await t.enterText(key('remote-user'), 'ersin');
  }

  Future<void> save(WidgetTester t) async {
    await press(t, 'remote-save');
  }

  Future<RemoteProfilesSnapshot> read() =>
      RemoteProfilesStore().read(isCurrent: () => true);
  Future<void> openFirst(WidgetTester t) async {
    final saved = await read();
    await press(t, 'remote-profile-${saved.profiles.first.id}');
  }
}
