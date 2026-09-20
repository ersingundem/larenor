import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/direct_home_access.dart';
import 'package:larenor/features/proxmox/data/models/proxmox_guest.dart';
import 'package:larenor/features/proxmox/data/models/proxmox_storage.dart';
import 'package:larenor/features/proxmox/data/proxmox_client.dart';
import 'package:larenor/features/proxmox/data/proxmox_config.dart';
import 'package:larenor/features/proxmox/presentation/console/proxmox_console_screen.dart';
import 'package:larenor/features/proxmox/presentation/proxmox_connect_screen.dart';
import 'package:larenor/features/proxmox/presentation/proxmox_create_guest_screen.dart';
import 'package:larenor/features/proxmox/providers/proxmox_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/app_page_scaffold.dart';
import 'package:larenor/shared/widgets/settings_section.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import '../dashboard/webview_tile_test.dart' show TestWebViewPlatform;

const _config = ProxmoxConfig(
  host: 'pve.test',
  port: 8006,
  username: 'fixture',
  realm: 'pam',
  password: 'fixture-password',
  allowSelfSigned: false,
);
const _template = ProxmoxGuest(
  type: ProxmoxGuestType.qemu,
  node: 'pve',
  vmid: 900,
  name: 'Living room template',
  status: 'stopped',
  isTemplate: true,
);
const _guest = ProxmoxGuest(
  type: ProxmoxGuestType.qemu,
  node: 'pve',
  vmid: 101,
  name: 'Living room',
  status: 'running',
);

class _Connection extends ProxmoxConnection {
  _Connection(this.value);
  final ProxmoxConfig? value;
  int signIns = 0;

  @override
  Future<ProxmoxConfig?> build() async {
    ref.watch(directHomeAccessProvider);
    return value;
  }

  @override
  Future<void> signIn({
    required String host,
    required int port,
    required String username,
    required String realm,
    required String password,
    required bool allowSelfSigned,
    bool Function()? isCurrent,
  }) async {
    if (isCurrent?.call() != false) signIns++;
  }
}

Future<void> _mount(
  WidgetTester tester, {
  required Locale locale,
  required double width,
  required Widget home,
  required _Connection connection,
  TestWebViewPlatform? web,
}) async {
  tester.view.physicalSize = Size(width, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final previousWeb = WebViewPlatform.instance;
  if (web != null) WebViewPlatform.instance = web;
  addTearDown(() {
    if (web != null) {
      WebViewPlatform.instance = previousWeb ?? TestWebViewPlatform();
    }
  });
  final client = ProxmoxClient(config: _config);
  addTearDown(client.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        proxmoxConnectionProvider.overrideWith(() => connection),
        proxmoxClientProvider.overrideWith((_) async => client),
        proxmoxGuestsProvider('pve').overrideWith((ref) async {
          await ref.watch(proxmoxClientProvider.future);
          return const [_template];
        }),
        proxmoxStoragesProvider('pve').overrideWith((ref) async {
          await ref.watch(proxmoxClientProvider.future);
          return const [
            ProxmoxStorage(
              name: 'local-zfs',
              type: 'zfspool',
              contentTypes: ['images'],
            ),
          ];
        }),
      ],
      child: CupertinoApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: home,
      ),
    ),
  );
  if (web == null) {
    await tester.pumpAndSettle();
  } else {
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump();
    }
  }
}

void _expectAction(WidgetTester tester, String key) {
  final action = find.byKey(ValueKey(key));
  expect(action, findsOneWidget);
  final rect = tester.getRect(action);
  expect(rect.width, greaterThanOrEqualTo(48));
  expect(rect.height, greaterThanOrEqualTo(48));
  expect(tester.getSemantics(action).flagsCollection.isButton, isTrue);
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/network_info'),
          (_) async => null,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/network_info'),
          null,
        );
  });

  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1200.0]) {
      testWidgets(
        '${locale.languageCode} connect fits ${width.toInt()} at 2x and submits from keyboard',
        (tester) async {
          final connection = _Connection(null);
          await _mount(
            tester,
            locale: locale,
            width: width,
            home: const ProxmoxConnectScreen(popOnSuccess: false),
            connection: connection,
          );
          expect(find.byType(AppSurface), findsAtLeastNWidgets(1));
          expect(find.byType(SettingsSection), findsAtLeastNWidgets(2));
          _expectAction(tester, 'proxmox-connect-submit');
          final fields = find.byType(CupertinoTextField);
          await tester.enterText(fields.at(0), 'pve.test');
          await tester.enterText(fields.at(4), 'fixture-password');
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await tester.pumpAndSettle();
          expect(connection.signIns, 1);
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets(
        '${locale.languageCode} template flow fits ${width.toInt()} at 2x and opens by Enter',
        (tester) async {
          await _mount(
            tester,
            locale: locale,
            width: width,
            home: const ProxmoxCreateGuestScreen(nodeName: 'pve'),
            connection: _Connection(_config),
          );
          expect(find.byType(AppSurface), findsOneWidget);
          expect(find.byType(SettingsSection), findsOneWidget);
          _expectAction(tester, 'proxmox-template-pve-qemu-900');
          final title = find.text(_template.name);
          Focus.of(tester.element(title)).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          for (var frame = 0; frame < 6; frame++) {
            await tester.pump();
          }
          _expectAction(tester, 'proxmox-clone-submit');
          _expectAction(tester, 'proxmox-clone-storage');
          expect(find.byType(AppSurface), findsAtLeastNWidgets(1));
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets(
        '${locale.languageCode} console fits ${width.toInt()} at 2x and opens route by Enter',
        (tester) async {
          final web = TestWebViewPlatform();
          await _mount(
            tester,
            locale: locale,
            width: width,
            home: const ProxmoxConsoleScreen(guest: _guest),
            connection: _Connection(_config),
            web: web,
          );
          expect(find.byType(AppSurface), findsOneWidget);
          expect(find.byType(SettingsSection), findsOneWidget);
          _expectAction(tester, 'proxmox-console-refresh');
          _expectAction(tester, 'proxmox-console-open');
          final open = find.byKey(const ValueKey('proxmox-console-open'));
          final openLabel = find.descendant(
            of: open,
            matching: find.byType(Text),
          );
          Focus.of(tester.element(openLabel)).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          for (var frame = 0; frame < 6; frame++) {
            await tester.pump();
          }
          expect(web.controllers.last.requests.last.uri.queryParameters, {
            'console': 'kvm',
            'novnc': '1',
            'vmid': '101',
            'node': 'pve',
            'resize': 'scale',
            'mobile': '0',
          });
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
