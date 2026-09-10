import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/core_proxmox/domain/core_proxmox_models.dart';
import 'package:larenor/features/core_proxmox/presentation/core_proxmox_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

CoreProxmoxSummary _summary() {
  final contract = jsonDecode(
    File('contracts/proxmox-resource.v1.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  return CoreProxmoxSummary.fromJson(contract['summary']);
}

Widget _app({Locale locale = const Locale('en'), double scale = 1}) =>
    CupertinoApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(900, 700),
          textScaler: TextScaler.linear(scale),
        ),
        child: CupertinoPageScaffold(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: CoreProxmoxSummaryPanel(summary: _summary()),
          ),
        ),
      ),
    );

void main() {
  testWidgets('tablet summary exposes typed status and metrics to TalkBack', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final semantics = tester.ensureSemantics();
    addTearDown(semantics.dispose);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('core-proxmox-node-pve-a')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('core-proxmox-guest-qemu-101')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('core-proxmox-storage-pve-a-local-lvm')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp(r'pve-a, Online, CPU: 25%')),
      findsOneWidget,
    );
    expect(find.textContaining('QEMU VM #101'), findsOneWidget);
    expect(find.textContaining('LXC container #102'), findsOneWidget);
  });

  testWidgets('two-times Turkish text falls back to one readable column', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(locale: const Locale('tr'), scale: 2));
    await tester.pumpAndSettle();

    expect(find.text('Çevrimiçi'), findsOneWidget);
    expect(find.textContaining('LXC konteyneri #102'), findsOneWidget);
    final first = tester.getSize(
      find.byKey(const ValueKey('core-proxmox-node-pve-a')),
    );
    expect(first.width, greaterThan(800));
    expect(tester.takeException(), isNull);
  });
}
