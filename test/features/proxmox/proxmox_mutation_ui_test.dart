import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/proxmox/data/models/proxmox_guest.dart';
import 'package:larenor/features/proxmox/data/models/proxmox_storage.dart';
import 'package:larenor/features/proxmox/data/proxmox_api_exception.dart';
import 'package:larenor/features/proxmox/data/proxmox_client.dart';
import 'package:larenor/features/proxmox/data/proxmox_config.dart';
import 'package:larenor/features/proxmox/presentation/proxmox_backups_screen.dart';
import 'package:larenor/features/proxmox/presentation/proxmox_create_guest_screen.dart';
import 'package:larenor/features/proxmox/presentation/proxmox_guest_detail_screen.dart';
import 'package:larenor/features/proxmox/presentation/widgets/proxmox_guest_row.dart';
import 'package:larenor/features/proxmox/providers/proxmox_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

const _config = ProxmoxConfig(
  host: 'proxmox.invalid',
  port: 8006,
  username: 'fixture',
  realm: 'pam',
  password: 'fixture',
  allowSelfSigned: false,
);
const _other = ProxmoxConfig(
  host: 'other.invalid',
  port: 8006,
  username: 'fixture',
  realm: 'pam',
  password: 'other',
  allowSelfSigned: false,
);
const _guest = ProxmoxGuest(
  type: ProxmoxGuestType.qemu,
  node: 'pve',
  vmid: 100,
  name: 'Home',
  status: 'running',
);
const _template = ProxmoxGuest(
  type: ProxmoxGuestType.qemu,
  node: 'pve',
  vmid: 900,
  name: 'Template',
  status: 'stopped',
  isTemplate: true,
);
const _storage = ProxmoxStorage(
  name: 'local',
  type: 'dir',
  contentTypes: ['images', 'backup'],
);

class _Connection extends ProxmoxConnection {
  @override
  Future<ProxmoxConfig?> build() async => _config;
  void change() => state = const AsyncData(_other);
  void loading() => state = const AsyncLoading();
}

class _Client extends ProxmoxClient {
  _Client(ProxmoxConfig config)
    : super(
        config: config,
        httpClient: MockClient((_) async => http.Response('unexpected', 500)),
      );
  final writes = <String>[];
  final changes = <Map<String, String>>[];
  Completer<String>? pending;
  Object? failure;
  Completer<ProxmoxTaskPoll?>? task;
  int polls = 0;
  @override
  bool get isAuthenticated => true;
  Future<String> _dispatch(String record) async {
    writes.add(record);
    if (failure != null) throw failure!;
    return pending?.future ?? 'UPID:fixture';
  }

  @override
  Future<String> powerAction(
    String node,
    ProxmoxGuestType type,
    int vmid,
    String action,
  ) => _dispatch('power:$node:$vmid:$action');
  @override
  Future<String> triggerBackup(
    String node, {
    required int vmid,
    required String storage,
  }) => _dispatch('backup:$node:$vmid:$storage');
  @override
  Future<String> cloneGuest(
    String node,
    ProxmoxGuestType type,
    int vmid, {
    required int newId,
    String? name,
    String? targetStorage,
    String? targetNode,
    bool full = true,
  }) => _dispatch('clone:$node:$vmid:$newId:$targetStorage');
  @override
  Future<void> updateGuestConfig(
    String node,
    ProxmoxGuestType type,
    int vmid,
    Map<String, String> values,
  ) async {
    changes.add(Map.of(values));
    await _dispatch('config:$node:$vmid');
  }

  @override
  Future<int> getNextGuestId() async => 201;
  @override
  Future<ProxmoxTaskPoll?> waitForTask(
    String node,
    String upid, {
    bool Function()? shouldContinue,
    Duration interval = const Duration(seconds: 2),
    Duration timeout = const Duration(hours: 1),
  }) async {
    polls++;
    if (shouldContinue?.call() == false) return null;
    final value =
        await (task?.future ??
            Future.value(
              const ProxmoxTaskPoll(isRunning: false, exitStatus: 'OK'),
            ));
    return shouldContinue?.call() == false ? null : value;
  }
}

class _Harness {
  final connection = _Connection();
  final first = _Client(_config);
  final second = _Client(_other);
  late ProviderContainer container;
  final rowGuest = ValueNotifier(_guest);
  int changed = 0;
  bool sourceCurrent = true;
  Future<void> mount(
    WidgetTester tester,
    String screen, {
    double scale = 1,
    Size size = const Size(1000, 1400),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        proxmoxConnectionProvider.overrideWith(() => connection),
        proxmoxClientProvider.overrideWith((ref) async {
          final c = ref.watch(proxmoxConnectionProvider);
          return c.isLoading || c.hasError
              ? null
              : c.value?.host == _config.host
              ? first
              : second;
        }),
        proxmoxGuestsProvider('pve').overrideWith((ref) async {
          await ref.watch(proxmoxClientProvider.future);
          return [_guest, _template];
        }),
        proxmoxStoragesProvider('pve').overrideWith((ref) async {
          await ref.watch(proxmoxClientProvider.future);
          return [_storage];
        }),
        proxmoxBackupsProvider('pve', 'local').overrideWith((ref) async {
          await ref.watch(proxmoxClientProvider.future);
          return [];
        }),
        proxmoxGuestConfigProvider(
          'pve',
          ProxmoxGuestType.qemu,
          100,
        ).overrideWith((ref) async {
          await ref.watch(proxmoxClientProvider.future);
          return {
            'name': 'Home',
            'cores': 2,
            'memory': 1024,
            'onboot': 1,
            'digest': 'version',
            'cipassword': 'PRIVATE-PASSWORD',
            'token': 'PRIVATE-TOKEN',
          };
        }),
        proxmoxTasksProvider('pve').overrideWith((ref) async => []),
      ],
    );
    addTearDown(() {
      container.dispose();
      first.dispose();
      second.dispose();
      rowGuest.dispose();
    });
    final connectionSub = container.listen(
      proxmoxConnectionProvider,
      (_, _) {},
    );
    addTearDown(connectionSub.close);
    await container.read(proxmoxConnectionProvider.future);
    final clientSub = container.listen(proxmoxClientProvider, (_, _) {});
    addTearDown(clientSub.close);
    await container.read(proxmoxClientProvider.future);
    Widget child() => switch (screen) {
      'row' => CupertinoPageScaffold(
        child: SafeArea(
          child: ValueListenableBuilder(
            valueListenable: rowGuest,
            builder: (context, guest, _) =>
                ProxmoxGuestRow(guest: guest, onChanged: () => changed++),
          ),
        ),
      ),
      'backup' => ProxmoxBackupsScreen(
        nodeName: 'pve',
        storageName: 'local',
        sourceCurrent: () => sourceCurrent,
      ),
      'clone' => ProxmoxCreateGuestScreen(
        nodeName: 'pve',
        sourceCurrent: () => sourceCurrent,
      ),
      _ => ProxmoxGuestDetailScreen(
        guest: _guest,
        sourceCurrent: () => sourceCurrent,
      ),
    };
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: CupertinoApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => CupertinoPageScaffold(
              child: Center(
                child: CupertinoButton(
                  onPressed: () => Navigator.push(
                    context,
                    CupertinoPageRoute(builder: (_) => child()),
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
  }
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

CupertinoButton _button(WidgetTester tester, String label) =>
    tester.widget<CupertinoButton>(
      find
          .ancestor(
            of: find.text(label),
            matching: find.byType(CupertinoButton),
          )
          .last,
    );
Future<void> _clone(WidgetTester tester) async {
  await _tap(tester, find.text('Template'));
}

Future<void> _editCores(WidgetTester tester) async {
  await tester.enterText(
    find.descendant(
      of: find.byType(CupertinoTextFormFieldRow).at(1),
      matching: find.byType(EditableText),
    ),
    '4',
  );
}

Future<void> _background(WidgetTester tester) async {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('backup duplicate popup callback sends one fixed target', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester, 'backup');
    final open = tester
        .widget<CupertinoButton>(
          find.ancestor(
            of: find.byIcon(CupertinoIcons.add),
            matching: find.byType(CupertinoButton),
          ),
        )
        .onPressed!;
    open();
    open();
    await tester.pumpAndSettle();
    final action = tester
        .widget<CupertinoActionSheetAction>(
          find.byType(CupertinoActionSheetAction).first,
        )
        .onPressed;
    action();
    action();
    await tester.pumpAndSettle();
    expect(h.first.writes, ['backup:pve:100:local']);
    expect(h.second.writes, isEmpty);
  });
  for (final change in ['account', 'background', 'source']) {
    testWidgets('backup $change rejects selected old guest', (tester) async {
      final h = _Harness();
      await h.mount(tester, 'backup');
      await _tap(tester, find.byIcon(CupertinoIcons.add));
      final action = tester
          .widget<CupertinoActionSheetAction>(
            find.byType(CupertinoActionSheetAction).first,
          )
          .onPressed;
      if (change == 'account') h.connection.change();
      if (change == 'source') h.sourceCurrent = false;
      if (change == 'background') await _background(tester);
      await tester.pumpAndSettle();
      action();
      await tester.pumpAndSettle();
      expect(h.first.writes, isEmpty);
      expect(h.second.writes, isEmpty);
    });
  }
  testWidgets('power double popup and callback submit only once', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester, 'row');
    final open = tester
        .widget<CupertinoButton>(
          find.ancestor(
            of: find.byIcon(CupertinoIcons.power),
            matching: find.byType(CupertinoButton),
          ),
        )
        .onPressed!;
    open();
    open();
    await tester.pumpAndSettle();
    final action = tester
        .widget<CupertinoActionSheetAction>(
          find.byType(CupertinoActionSheetAction).first,
        )
        .onPressed;
    action();
    action();
    await tester.pumpAndSettle();
    expect(h.first.writes, ['power:pve:100:shutdown']);
    expect(h.changed, 1);
  });
  testWidgets('reused guest row cannot send old action to replacement VM', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester, 'row');
    await _tap(tester, find.byIcon(CupertinoIcons.power));
    final action = tester
        .widget<CupertinoActionSheetAction>(
          find.byType(CupertinoActionSheetAction).first,
        )
        .onPressed;
    h.rowGuest.value = const ProxmoxGuest(
      type: ProxmoxGuestType.qemu,
      node: 'pve',
      vmid: 101,
      name: 'Other',
      status: 'running',
    );
    await tester.pumpAndSettle();
    action();
    await tester.pumpAndSettle();
    expect(h.first.writes, isEmpty);
  });
  testWidgets(
    'power response timeout is redacted and blocks same-screen replay',
    (tester) async {
      final h = _Harness();
      h.first.failure = ProxmoxApiException(
        'PRIVATE-ERROR',
        failure: ProxmoxFailure.timeout,
      );
      await h.mount(tester, 'row');
      await _tap(tester, find.byIcon(CupertinoIcons.power));
      await _tap(tester, find.byType(CupertinoActionSheetAction).first);
      expect(find.textContaining('PRIVATE-ERROR'), findsNothing);
      expect(find.textContaining('Check Activity'), findsWidgets);
      await _tap(tester, find.text('OK'));
      expect(
        tester
            .widget<CupertinoButton>(
              find.ancestor(
                of: find.byIcon(CupertinoIcons.power),
                matching: find.byType(CupertinoButton),
              ),
            )
            .onPressed,
        isNull,
      );
      expect(h.first.writes, hasLength(1));
    },
  );
  testWidgets(
    'clone selected template and storage stay scoped and single-flight',
    (tester) async {
      final h = _Harness();
      h.first.pending = Completer<String>();
      await h.mount(tester, 'clone');
      await _clone(tester);
      final create = _button(tester, 'Create').onPressed!;
      create();
      create();
      await tester.pump();
      expect(h.first.writes, ['clone:pve:900:201:local']);
      h.first.pending!.complete('UPID:fixture');
      await tester.pumpAndSettle();
      expect(h.first.writes, hasLength(1));
    },
  );
  for (final change in ['account', 'background', 'source']) {
    testWidgets('clone $change invalidates form and saved submit callback', (
      tester,
    ) async {
      final h = _Harness();
      await h.mount(tester, 'clone');
      await _clone(tester);
      final create = _button(tester, 'Create').onPressed!;
      if (change == 'account') h.connection.change();
      if (change == 'source') h.sourceCurrent = false;
      if (change == 'background') await _background(tester);
      await tester.pumpAndSettle();
      create();
      await tester.pumpAndSettle();
      expect(h.first.writes, isEmpty);
      expect(h.second.writes, isEmpty);
    });
  }
  testWidgets(
    'guest config hides credential values and writes changes plus digest once',
    (tester) async {
      final h = _Harness();
      h.first.pending = Completer<String>();
      await h.mount(tester, 'detail');
      expect(find.textContaining('PRIVATE-'), findsNothing);
      expect(find.byType(CupertinoTextFormFieldRow), findsNWidgets(3));
      await _editCores(tester);
      final save = _button(tester, 'Save').onPressed!;
      save();
      save();
      await tester.pump();
      expect(h.first.changes, [
        {'cores': '4', 'digest': 'version'},
      ]);
      h.first.pending!.complete('UPID:fixture');
      await tester.pumpAndSettle();
      expect(h.first.writes, ['config:pve:100']);
    },
  );
  for (final change in ['account', 'background', 'source']) {
    testWidgets('guest detail $change cannot submit stale draft', (
      tester,
    ) async {
      final h = _Harness();
      await h.mount(tester, 'detail');
      await _editCores(tester);
      final save = _button(tester, 'Save').onPressed!;
      if (change == 'account') h.connection.change();
      if (change == 'source') h.sourceCurrent = false;
      if (change == 'background') await _background(tester);
      await tester.pumpAndSettle();
      save();
      await tester.pumpAndSettle();
      expect(h.first.writes, isEmpty);
      expect(h.second.writes, isEmpty);
    });
  }
  testWidgets('closing pending config save ignores late errors', (
    tester,
  ) async {
    final h = _Harness();
    h.first.pending = Completer<String>();
    await h.mount(tester, 'detail');
    await _editCores(tester);
    _button(tester, 'Save').onPressed!();
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    h.first.pending!.completeError(
      ProxmoxApiException('PRIVATE-LATE', failure: ProxmoxFailure.timeout),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'polling stops on account change and never uses replacement client',
    (tester) async {
      final h = _Harness();
      h.first.task = Completer<ProxmoxTaskPoll?>();
      await h.mount(tester, 'backup');
      await _tap(tester, find.byIcon(CupertinoIcons.add));
      tester
          .widget<CupertinoActionSheetAction>(
            find.byType(CupertinoActionSheetAction).first,
          )
          .onPressed();
      await tester.pump();
      h.connection.change();
      await tester.pump();
      h.first.task!.complete(
        const ProxmoxTaskPoll(isRunning: false, exitStatus: 'OK'),
      );
      await tester.pumpAndSettle();
      expect(h.first.writes, ['backup:pve:100:local']);
      expect(h.first.polls, 1);
      expect(h.second.writes, isEmpty);
      expect(h.second.polls, 0);
    },
  );
  for (final screen in ['clone', 'detail', 'backup']) {
    testWidgets('$screen fits 320px at 2x text', (tester) async {
      final h = _Harness();
      await h.mount(tester, screen, size: const Size(320, 1000), scale: 2);
      if (screen == 'clone') await _clone(tester);
      expect(tester.takeException(), isNull);
    });
  }
}
