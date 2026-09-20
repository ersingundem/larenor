import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/direct_home_access.dart';
import 'package:larenor/features/proxmox/data/models/proxmox_guest.dart';
import 'package:larenor/features/proxmox/data/models/proxmox_storage.dart';
import 'package:larenor/features/proxmox/data/models/proxmox_task.dart';
import 'package:larenor/features/proxmox/data/proxmox_client.dart';
import 'package:larenor/features/proxmox/data/proxmox_config.dart';
import 'package:larenor/features/proxmox/presentation/proxmox_guest_detail_screen.dart';
import 'package:larenor/features/proxmox/presentation/proxmox_node_detail_screen.dart';
import 'package:larenor/features/proxmox/presentation/proxmox_tasks_screen.dart';
import 'package:larenor/features/proxmox/providers/proxmox_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/app_page_scaffold.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

const _config = ProxmoxConfig(
  host: 'pve.test',
  port: 8006,
  username: 'fixture',
  realm: 'pam',
  password: 'fixture',
  allowSelfSigned: false,
);

const _guest = ProxmoxGuest(
  type: ProxmoxGuestType.qemu,
  node: 'pve',
  vmid: 101,
  name: 'Living room',
  status: 'running',
  cpuFraction: .25,
  mem: 1,
  maxMem: 2,
);

class _Connection extends ProxmoxConnection {
  @override
  Future<ProxmoxConfig?> build() async {
    ref.watch(directHomeAccessProvider);
    return _config;
  }
}

Widget _app(Locale locale, Widget home) => CupertinoApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context)
        .copyWith(textScaler: const TextScaler.linear(2)),
    child: child!,
  ),
  home: home,
);

Future<void> _mount(
  WidgetTester tester, {
  required Locale locale,
  required double width,
  required Widget home,
}) async {
  tester.view.physicalSize = Size(width, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final client = ProxmoxClient(config: _config);
  addTearDown(client.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        proxmoxConnectionProvider.overrideWith(_Connection.new),
        proxmoxClientProvider.overrideWith((_) async => client),
        proxmoxGuestsProvider('pve').overrideWith((_) async => const [_guest]),
        proxmoxStoragesProvider('pve').overrideWith(
          (_) async => const [
            ProxmoxStorage(
              name: 'local',
              type: 'dir',
              contentTypes: ['backup', 'images'],
              total: 2,
              used: 1,
            ),
          ],
        ),
        proxmoxTasksProvider('pve').overrideWith(
          (_) async => const [
            ProxmoxTask(
              upid: 'UPID:pve:fixture',
              type: 'backup',
              resourceId: '101',
              status: 'OK',
            ),
          ],
        ),
        proxmoxGuestConfigProvider(
          'pve',
          ProxmoxGuestType.qemu,
          101,
        ).overrideWith(
          (_) async => const {
            'name': 'Living room',
            'cores': 2,
            'memory': 2048,
            'onboot': 1,
            'digest': 'fixture-digest',
          },
        ),
      ],
      child: _app(locale, home),
    ),
  );
  await tester.pumpAndSettle();
}

void _expectAction(WidgetTester tester, String key) {
  final finder = find.byKey(ValueKey(key));
  expect(finder, findsOneWidget);
  final rect = tester.getRect(finder);
  expect(rect.width, greaterThanOrEqualTo(48));
  expect(rect.height, greaterThanOrEqualTo(48));
  expect(tester.getSemantics(finder).flagsCollection.isButton, isTrue);
}

void main() {
  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1200.0]) {
      testWidgets('${locale.languageCode} Proxmox node workflow fits '
          '${width.toInt()}px at 2x text', (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          await _mount(
            tester,
            locale: locale,
            width: width,
            home: const ProxmoxNodeDetailScreen(nodeName: 'pve'),
          );
          expect(find.byType(AppSurface), findsOneWidget);
          expect(find.byType(SettingsSection), findsAtLeastNWidgets(3));
          for (final key in const [
            'proxmox-node-refresh',
            'proxmox-node-add',
            'proxmox-node-tasks',
            'proxmox-storage-local',
          ]) {
            _expectAction(tester, key);
          }
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });

      testWidgets('${locale.languageCode} Proxmox guest workflow fits '
          '${width.toInt()}px at 2x text', (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          await _mount(
            tester,
            locale: locale,
            width: width,
            home: const ProxmoxGuestDetailScreen(guest: _guest),
          );
          expect(find.byType(AppSurface), findsOneWidget);
          expect(find.byType(SettingsSection), findsNWidgets(2));
          _expectAction(tester, 'proxmox-guest-console');
          _expectAction(tester, 'proxmox-guest-save');
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });

      testWidgets('${locale.languageCode} Proxmox task workflow fits '
          '${width.toInt()}px at 2x text', (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          await _mount(
            tester,
            locale: locale,
            width: width,
            home: const ProxmoxTasksScreen(nodeName: 'pve'),
          );
          expect(find.byType(AppSurface), findsOneWidget);
          expect(find.byType(SettingsSection), findsAtLeastNWidgets(2));
          _expectAction(tester, 'proxmox-tasks-refresh');
          _expectAction(tester, 'proxmox-task-UPID:pve:fixture');
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });
    }
  }
}
