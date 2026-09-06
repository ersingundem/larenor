import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/home_scope/presentation/core_home_status_screen.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/presentation/server_connection_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import 'home_scope_fixture.dart';

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
  @override
  final _LogoutApi api = _LogoutApi()..requireChange = false;
}

void main() {
  testWidgets('Core late logout failure remains visible after protected account route retires', (tester) async {
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
    final l10n = AppLocalizations.of(tester.element(find.byType(ServerConnectionScreen)));
    await press(tester, 'server-sign-out');
    await tester.tap(find.widgetWithText(CupertinoDialogAction, l10n.serverSignOut));
    await flush(tester);
    expect(h.account.session, isNull);
    expect(h.source.value, HomeSource.verifiedCore);
    expect(find.byType(ServerConnectionScreen), findsNothing);
    expect(find.byType(CoreHomeStatusScreen), findsOneWidget);
    h.api.logoutReply.completeError(const LarenorServerException('connection_failed'));
    await flush(tester);
    expect(h.account.failure, 'logout_not_confirmed');
    expect(find.text(l10n.serverLogoutUnconfirmed), findsOneWidget);
    expect(h.connectionReads, 0);
    expect(h.api.logouts, 1);
    await tester.tap(find.text(l10n.homeCoreManageAccount));
    await flush(tester);
    expect(find.text(l10n.settingsGateUnlockButton), findsOneWidget);
    expect(find.byType(ServerConnectionScreen), findsNothing);
  });
}
