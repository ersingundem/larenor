import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/home_scope/presentation/core_home_status_screen.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/presentation/server_connection_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import 'home_scope_fixture.dart';
import '../features/server/server_connection_screen_test.dart' as server;

class _LogoutApi extends ScopeApi {
  final logoutReply = Completer<void>();
  @override
  Future<void> logout(ServerSession session) async {
    logouts++;
    await logoutReply.future;
  }
}

class _Harness extends ScopeHarness {
  _Harness() : super(HomeSource.verifiedCore);
  final _logoutApi = _LogoutApi()..requireChange = false;
  final _logoutStore = _LogoutStore();
  @override
  _LogoutApi get api => _logoutApi;
  @override
  _LogoutStore get store => _logoutStore;
}

class _LogoutStore extends server.Store {
  bool failClear = false;
  @override
  Future<void> write(ServerSession? value) async {
    if (value == null && failClear) {
      throw const LarenorServerException('storage_failed');
    }
    await super.write(value);
  }
}

void main() {
  testWidgets(
    'Core late logout failure remains visible after protected account route retires',
    (tester) async {
      final h = _Harness();
      await h.mount(tester, pin: '1234');
      await h.signIn();
      await flush(tester);
      h.router(tester).push('/settings');
      await flush(tester);
      await tester.enterText(find.byType(CupertinoTextField), '1234');
      await tester.tap(find.text('Unlock'));
      await flush(tester);
      expect(find.byType(ServerConnectionScreen), findsOneWidget);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(ServerConnectionScreen)),
      );
      await press(tester, 'server-sign-out');
      await tester.tap(
        find.widgetWithText(CupertinoDialogAction, l10n.serverSignOut),
      );
      await flush(tester);
      expect(h.account.session, isNull);
      expect(h.source.value, HomeSource.verifiedCore);
      expect(find.byType(ServerConnectionScreen), findsNothing);
      expect(find.byType(CoreHomeStatusScreen), findsOneWidget);
      h.api.logoutReply.completeError(
        const LarenorServerException('connection_failed'),
      );
      await flush(tester);
      expect(h.account.failure, 'logout_not_confirmed');
      expect(find.text(l10n.serverLogoutUnconfirmed), findsOneWidget);
      expect(h.connectionReads, 0);
      expect(h.api.logouts, 1);
      await tester.tap(find.text(l10n.homeCoreManageAccount));
      await flush(tester);
      expect(find.text(l10n.settingsGateUnlockButton), findsOneWidget);
      expect(find.byType(ServerConnectionScreen), findsNothing);
    },
  );

  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      for (final storageFailure in [false, true]) {
        testWidgets(
          '$language $width 2x logout ${storageFailure ? 'storage' : 'remote'} failure keeps source and PIN recovery',
          (tester) async {
            final semantics = tester.ensureSemantics();
            try {
              final h = _Harness();
              await h.mount(
                tester,
                pin: '1234',
                locale: language,
                width: width,
                scale: 2,
              );
              await h.signIn();
              await flush(tester);
              final l10n = AppLocalizations.of(
                tester.element(find.byType(CoreHomeStatusScreen)),
              );
              await tester.tap(find.text(l10n.homeCoreManageAccount));
              await flush(tester);
              await tester.enterText(find.byType(CupertinoTextField), '1234');
              await tester.tap(find.text(l10n.settingsGateUnlockButton));
              await flush(tester);
              h.store.failClear = storageFailure;
              await press(tester, 'server-sign-out');
              await tester.tap(
                find.widgetWithText(CupertinoDialogAction, l10n.serverSignOut),
              );
              await flush(tester);
              expect(find.byType(ServerConnectionScreen), findsNothing);
              h.api.logoutReply.completeError(
                const LarenorServerException('timeout'),
              );
              await flush(tester);
              final message = storageFailure
                  ? l10n.serverFailureStorage
                  : l10n.serverLogoutUnconfirmed;
              expect(find.text(message), findsOneWidget);
              expect(find.bySemanticsLabel(message), findsOneWidget);
              expect(h.account.session, isNull);
              expect(h.account.hasPendingContext, isFalse);
              expect(h.source.value, HomeSource.verifiedCore);
              expect(h.connectionReads, 0);
              expect(tester.takeException(), isNull);
              await tester.ensureVisible(find.text(l10n.homeCoreManageAccount));
              await tester.tap(find.text(l10n.homeCoreManageAccount));
              await flush(tester);
              expect(find.text(l10n.settingsGateUnlockButton), findsOneWidget);
              expect(find.byType(ServerConnectionScreen), findsNothing);
            } finally {
              semantics.dispose();
            }
          },
        );
      }
    }
  }
}
