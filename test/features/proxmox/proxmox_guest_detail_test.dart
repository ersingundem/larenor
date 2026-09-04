import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/proxmox/data/models/proxmox_guest.dart';
import 'package:larenor/features/proxmox/data/proxmox_client.dart';
import 'package:larenor/features/proxmox/data/proxmox_config.dart';
import 'package:larenor/features/proxmox/presentation/proxmox_guest_detail_screen.dart';
import 'package:larenor/features/proxmox/providers/proxmox_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

void main() {
  testWidgets('editing cores writes only the change and concurrency digest', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const guest = ProxmoxGuest(
      type: ProxmoxGuestType.lxc,
      node: 'pve1',
      vmid: 100,
      name: 'Home',
      status: 'stopped',
    );
    const config = ProxmoxConfig(
      host: 'pve.local',
      port: 8006,
      username: 'root',
      realm: 'pam',
      password: 'example',
      allowSelfSigned: false,
    );
    final writes = <Map<String, String>>[];
    final client = ProxmoxClient(
      config: config,
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/access/ticket')) {
          return http.Response(
            jsonEncode({
              'data': {'ticket': 'ticket', 'CSRFPreventionToken': 'csrf'},
            }),
            200,
          );
        }
        if (request.method == 'PUT') writes.add(request.bodyFields);
        return http.Response(jsonEncode({'data': null}), 200);
      }),
    );
    addTearDown(client.dispose);
    await client.login();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          proxmoxClientProvider.overrideWith((ref) async => client),
          proxmoxGuestConfigProvider(
            'pve1',
            ProxmoxGuestType.lxc,
            100,
          ).overrideWith((ref) async {
            await ref.watch(proxmoxClientProvider.future);
            return {
              'hostname': 'Home',
              'cores': 2,
              'memory': 1024,
              'onboot': 1,
              'unprivileged': 1,
              'digest': 'config-version',
              'lock': 'backup',
            };
          }),
        ],
        child: CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Builder(
            builder: (context) => CupertinoPageScaffold(
              child: Center(
                child: CupertinoButton(
                  onPressed: () => Navigator.of(context).push(
                    CupertinoPageRoute<void>(
                      builder: (_) =>
                          const ProxmoxGuestDetailScreen(guest: guest),
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoSwitch), findsOneWidget);
    // hostname, cores, memory, unprivileged; no second onboot text field and
    // no editable digest/lock controls.
    expect(find.byType(CupertinoTextFormFieldRow), findsNWidgets(4));
    final cores = find.descendant(
      of: find.byType(CupertinoTextFormFieldRow).at(1),
      matching: find.byType(EditableText),
    );
    await tester.enterText(cores, '4');
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(writes, [
      {'cores': '4', 'digest': 'config-version'},
    ]);
    expect(tester.takeException(), isNull);
  });
}
