import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/home_resources/data/home_resources_api.dart';
import 'package:larenor/features/home_resources/data/home_resource_grants_controller.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/home_resources/domain/home_resource_grants.dart';
import 'package:larenor/features/server/admin/domain/server_admin_models.dart';

import '../../core/home_scope_fixture.dart' show flush;
import 'home_resource_grants_ui_test.dart';

Future<HomeResourceGrantsController> controller(
  WidgetTester tester,
  GrantsHarness h, {
  bool Function()? current,
}) async {
  await h.mount(tester);
  await h.signIn();
  await flush(tester);
  final c = HomeResourceGrantsController(
    h.home(tester),
    HomeResourceRecord.fromJson(
      h.records.first,
      expectedContext: h.account.session!.context!,
    ),
    h.runtime(tester).read(homeResourcesApiFactoryProvider),
    () => h.now,
    current ?? () => true,
  );
  return c;
}

void main() {
  testWidgets(
    'manual subject object and denied or throwing owner dispatch no PUT',
    (tester) async {
      final h = GrantsHarness(), c = await controller(tester, h);
      c.setVisible(true);
      await flush(tester);
      await c.setPermission(
        AdminUser.fromJson(h.users[1]),
        HomeResourcePermission.readWrite,
        isCurrent: () => true,
      );
      await c.setPermission(
        c.users[1],
        HomeResourcePermission.readWrite,
        isCurrent: () => false,
      );
      await c.setPermission(
        c.users[1],
        HomeResourcePermission.readWrite,
        isCurrent: () => throw StateError('private'),
      );
      expect(h.puts, isEmpty);
      expect(c.snapshot, isNotNull);
      c.dispose();
    },
  );
  for (final revoked in [false, true]) {
    testWidgets(
      'user GET late ${revoked ? '401' : 'success'} after authority loss cannot start ACL GET',
      (tester) async {
        final h = GrantsHarness();
        bool current = true;
        final c = await controller(tester, h, current: () => current),
            late = Completer<http.Response>();
        h.pendingUsers = late;
        c.setVisible(true);
        await flush(tester);
        expect(h.userReads, 1);
        expect(h.grantReads, 0);
        current = false;
        late.complete(
          h.json(
            revoked
                ? {
                    'error': {'code': 'unauthorized'},
                  }
                : {'users': h.users},
            revoked ? 401 : 200,
          ),
        );
        await flush(tester);
        expect(h.grantReads, 0);
        expect(h.account.session, isNotNull);
        expect(c.users, isEmpty);
        c.dispose();
      },
    );
  }
  for (final invalid in ['newline', 'duplicate', 'overLimit']) {
    testWidgets('invalid $invalid users fail closed before grant GET', (
      tester,
    ) async {
      final h = GrantsHarness(), c = await controller(tester, h);
      if (invalid == 'newline') h.users[0]['id'] = '${'2' * 32}\n';
      if (invalid == 'duplicate') h.users[0]['id'] = h.users[1]['id']!;
      if (invalid == 'overLimit') {
        h.users.addAll(
          List.generate(
            254,
            (i) => {
              ...h.users[0],
              'id': (i + 50).toRadixString(16).padLeft(32, '0'),
            },
          ),
        );
      }
      c.setVisible(true);
      await flush(tester);
      expect(c.failure, 'invalid_response');
      expect(c.users, isEmpty);
      expect(h.grantReads, 0);
      expect(h.puts, isEmpty);
      c.dispose();
    });
  }
  testWidgets(
    'confirmed no-op keeps ACL revision while corrupt PUT clears for explicit read',
    (tester) async {
      final h = GrantsHarness()
        ..grants['3' * 32] = {'read': true, 'write': false};
      final c = await controller(tester, h);
      c.setVisible(true);
      await flush(tester);
      await c.setPermission(
        c.users[1],
        HomeResourcePermission.readOnly,
        isCurrent: () => true,
      );
      await flush(tester);
      expect(c.snapshot!.aclRevision, 1);
      expect(c.outcome, HomeResourceGrantOutcome.saved);
      h.corruptGrant = true;
      await c.setPermission(
        c.users[1],
        HomeResourcePermission.readWrite,
        isCurrent: () => true,
      );
      await flush(tester);
      expect(c.snapshot, isNull);
      expect(c.users, isEmpty);
      expect(c.outcome, HomeResourceGrantOutcome.uncertain);
      expect(h.puts.length, 2);
      expect(h.grantReads, 1);
      await c.refresh();
      await flush(tester);
      expect(h.puts.length, 2);
      expect(
        c.snapshot!.permissionFor('3' * 32),
        HomeResourcePermission.readWrite,
      );
      c.dispose();
    },
  );
  testWidgets(
    'no users is a valid empty read and exposes no invented subject',
    (tester) async {
      final h = GrantsHarness()..users.clear();
      final c = await controller(tester, h);
      c.setVisible(true);
      await flush(tester);
      expect(c.failure, isNull);
      expect(c.snapshot, isNotNull);
      expect(c.users, isEmpty);
      expect(h.puts, isEmpty);
      c.dispose();
    },
  );
}
