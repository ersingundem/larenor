import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/keenetic/core_command/core_keenetic_command.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

CoreKeeneticCommandTarget target({String kind = 'guest_wifi'}) =>
    CoreKeeneticCommandTarget.syntheticForTest(
      targetKind: kind,
      targetId: kind == 'client' ? 'AA:BB:CC:DD:EE:FF' : 'Guest',
      value: kind == 'guest_wifi' ? 'disabled' : 'online',
    );

class FakeCoreKeeneticCommandApi implements CoreKeeneticCommandApi {
  FakeCoreKeeneticCommandApi({this.highRisk = false});
  final bool highRisk;
  int previews = 0, effects = 0, cancels = 0;
  CoreKeeneticCommandPreview? current;
  bool challenged = false;

  @override
  Future<CoreKeeneticCommandPreview> preview(
    CoreKeeneticCommandAction action,
    CoreKeeneticCommandTarget target,
  ) async {
    previews++;
    return current = CoreKeeneticCommandPreview(
      id: 'preview',
      confirmToken: 'first',
      requestId: 'request',
      action: action,
      targetFingerprint: target.fingerprint,
      highRisk: highRisk,
    );
  }

  @override
  Future<CoreKeeneticConfirmResult> confirm(
    String previewId,
    String token,
  ) async {
    if (highRisk && !challenged) {
      challenged = true;
      return const CoreKeeneticNeedsConfirmation(
        CoreKeeneticConfirmation('second'),
      );
    }
    effects++;
    return const CoreKeeneticFinished(
      CoreKeeneticCommandReceipt(
        CoreKeeneticCommandStatus.succeeded,
        'succeeded',
      ),
    );
  }

  @override
  Future<CoreKeeneticCommandReceipt> cancel(String previewId) async {
    cancels++;
    return const CoreKeeneticCommandReceipt(
      CoreKeeneticCommandStatus.cancelled,
      'cancelled',
    );
  }

  @override
  Future<CoreKeeneticCommandReceipt> status(String requestId) async =>
      const CoreKeeneticCommandReceipt(
        CoreKeeneticCommandStatus.succeeded,
        'succeeded',
      );
}

class HeldCoreKeeneticCommandApi extends FakeCoreKeeneticCommandApi {
  final pending = Completer<CoreKeeneticCommandPreview>();

  @override
  Future<CoreKeeneticCommandPreview> preview(
    CoreKeeneticCommandAction action,
    CoreKeeneticCommandTarget target,
  ) {
    previews++;
    return pending.future;
  }
}

Widget app(Widget child, {Locale locale = const Locale('en')}) => CupertinoApp(
  locale: locale,
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: MediaQuery(
    data: const MediaQueryData(
      size: Size(600, 900),
      textScaler: TextScaler.linear(2),
    ),
    child: child,
  ),
);

void main() {
  testWidgets('member sees current state without command actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        CoreKeeneticCommandPanel(
          target: target(),
          isAdmin: false,
          canWrite: false,
          api: const UnavailableCoreKeeneticCommandApi(),
        ),
      ),
    );
    expect(find.text('Guest Wi-Fi'), findsOneWidget);
    expect(find.text('Enable'), findsNothing);
    expect(find.text('Disable'), findsNothing);
  });

  testWidgets('admin gets explicit preview and one-use confirmation', (
    tester,
  ) async {
    final api = FakeCoreKeeneticCommandApi();
    await tester.pumpWidget(
      app(
        CoreKeeneticCommandPanel(
          target: target(),
          isAdmin: true,
          canWrite: true,
          api: api,
        ),
      ),
    );
    await tester.tap(find.text('Enable'));
    await tester.pump();
    expect(find.text('Review command'), findsOneWidget);
    expect(api.effects, 0);
    await tester.tap(find.text('Confirm'));
    await tester.pump();
    expect(api.effects, 1);
    expect(find.text('Succeeded'), findsOneWidget);
  });

  testWidgets('WAN reconnect renders a distinct second confirmation', (
    tester,
  ) async {
    final api = FakeCoreKeeneticCommandApi(highRisk: true);
    await tester.pumpWidget(
      app(
        CoreKeeneticCommandPanel(
          target: target(kind: 'wan'),
          isAdmin: true,
          canWrite: true,
          api: api,
        ),
      ),
    );
    await tester.tap(find.text('Reconnect WAN'));
    await tester.pump();
    await tester.tap(find.text('Confirm'));
    await tester.pump();
    expect(find.text('Confirm WAN reconnect again'), findsOneWidget);
    expect(api.effects, 0);
    await tester.tap(find.text('Confirm again'));
    await tester.pump();
    expect(api.effects, 1);
  });

  testWidgets('default unavailable API is honest and opens no transport', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        CoreKeeneticCommandPanel(
          target: target(),
          isAdmin: true,
          canWrite: true,
          api: const UnavailableCoreKeeneticCommandApi(),
        ),
        locale: const Locale('tr'),
      ),
    );
    await tester.tap(find.text('Etkinleştir'));
    await tester.pump();
    expect(
      find.textContaining('Komut denetimleri kullanılamıyor'),
      findsOneWidget,
    );
  });

  testWidgets('cancel and lifecycle retirement cannot execute a held preview', (
    tester,
  ) async {
    final api = FakeCoreKeeneticCommandApi();
    await tester.pumpWidget(
      app(
        CoreKeeneticCommandPanel(
          target: target(),
          isAdmin: true,
          canWrite: true,
          api: api,
        ),
      ),
    );
    await tester.tap(find.text('Enable'));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(find.text('Confirm'), findsNothing);
    expect(api.cancels, 1);
    expect(api.effects, 0);
  });

  testWidgets('live parent authority loss disables actions before a request', (
    tester,
  ) async {
    final api = FakeCoreKeeneticCommandApi();
    var authorityCurrent = true;
    late StateSetter rebuild;
    await tester.pumpWidget(
      app(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return CoreKeeneticCommandPanel(
              target: target(),
              isAdmin: true,
              canWrite: true,
              isCurrent: () => authorityCurrent,
              api: api,
            );
          },
        ),
      ),
    );
    expect(find.text('Enable'), findsOneWidget);

    rebuild(() => authorityCurrent = false);
    await tester.pump();

    expect(find.text('Enable'), findsNothing);
    expect(
      find.text('This account can view router state but cannot run commands.'),
      findsOneWidget,
    );
    expect(api.previews, 0);
  });

  testWidgets('parent authority loss discards a late preview', (tester) async {
    final api = HeldCoreKeeneticCommandApi();
    var authorityCurrent = true;
    late StateSetter rebuild;
    await tester.pumpWidget(
      app(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return CoreKeeneticCommandPanel(
              target: target(),
              isAdmin: true,
              canWrite: true,
              isCurrent: () => authorityCurrent,
              api: api,
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('Enable'));
    await tester.pump();
    expect(api.previews, 1);

    rebuild(() => authorityCurrent = false);
    await tester.pump();
    api.pending.complete(
      CoreKeeneticCommandPreview(
        id: 'late-preview',
        confirmToken: 'late-token',
        requestId: 'late-request',
        action: CoreKeeneticCommandAction.guestWifiEnable,
        targetFingerprint: target().fingerprint,
        highRisk: false,
      ),
    );
    await tester.pump();

    expect(find.text('Review command'), findsNothing);
    expect(find.text('Confirm'), findsNothing);
    expect(api.effects, 0);
    expect(api.cancels, 0);
  });

  testWidgets('API replacement cancels an accepted preview through its owner', (
    tester,
  ) async {
    final oldApi = FakeCoreKeeneticCommandApi();
    final newApi = FakeCoreKeeneticCommandApi();
    await tester.pumpWidget(
      app(
        CoreKeeneticCommandPanel(
          target: target(),
          isAdmin: true,
          canWrite: true,
          api: oldApi,
        ),
      ),
    );
    await tester.tap(find.text('Enable'));
    await tester.pump();
    expect(find.text('Confirm'), findsOneWidget);

    await tester.pumpWidget(
      app(
        CoreKeeneticCommandPanel(
          target: target(kind: 'client'),
          isAdmin: true,
          canWrite: true,
          api: newApi,
        ),
      ),
    );
    await tester.pump();

    expect(oldApi.cancels, 1);
    expect(newApi.cancels, 0);
    expect(oldApi.effects, 0);
    expect(newApi.effects, 0);
  });

  testWidgets('API replacement retires and owner-cancels a late preview', (
    tester,
  ) async {
    final oldApi = HeldCoreKeeneticCommandApi();
    final newApi = FakeCoreKeeneticCommandApi();
    await tester.pumpWidget(
      app(
        CoreKeeneticCommandPanel(
          target: target(),
          isAdmin: true,
          canWrite: true,
          api: oldApi,
        ),
      ),
    );
    await tester.tap(find.text('Enable'));
    await tester.pump();

    await tester.pumpWidget(
      app(
        CoreKeeneticCommandPanel(
          target: target(kind: 'client'),
          isAdmin: true,
          canWrite: true,
          api: newApi,
        ),
      ),
    );
    oldApi.pending.complete(
      CoreKeeneticCommandPreview(
        id: 'late-preview',
        confirmToken: 'late-token',
        requestId: 'late-request',
        action: CoreKeeneticCommandAction.guestWifiEnable,
        targetFingerprint: target().fingerprint,
        highRisk: false,
      ),
    );
    await tester.pump();

    expect(find.text('Confirm'), findsNothing);
    expect(oldApi.cancels, 1);
    expect(newApi.cancels, 0);
    expect(oldApi.effects, 0);
    expect(newApi.effects, 0);
  });

  for (final width in [600.0, 1280.0]) {
    testWidgets('$width tablet keeps actions accessible at 2x text', (
      tester,
    ) async {
      await tester.pumpWidget(
        CupertinoApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 900),
              textScaler: const TextScaler.linear(2),
            ),
            child: CoreKeeneticCommandPanel(
              target: target(),
              isAdmin: true,
              canWrite: true,
              api: FakeCoreKeeneticCommandApi(),
            ),
          ),
        ),
      );
      final button = find.ancestor(
        of: find.text('Enable'),
        matching: find.byType(CupertinoButton),
      );
      expect(button, findsOneWidget);
      expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull);
    });
  }
}
