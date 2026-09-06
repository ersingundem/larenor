import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../core/home_scope_fixture.dart' show flush;
import 'home_resource_admin_fixture.dart';

void main() {
  testWidgets(
    'invalid label and order stay local then no-op edit preserves revisions',
    (tester) async {
      final h = ResourceAdminHarness();
      await openAdmin(tester, h);
      await adminPress(tester, 'home-resource-admin-create');
      for (final values in [
        ('', '0'),
        ('valid', '-1'),
        ('valid', '10001'),
        ('valid', 'not a number'),
      ]) {
        await tester.enterText(adminKey('home-resource-label'), values.$1);
        await tester.enterText(adminKey('home-resource-order'), values.$2);
        await adminPress(tester, 'home-resource-save');
        expect(h.mutations, isEmpty);
      }
      await adminPress(tester, 'home-resource-cancel-edit');
      final row = Map<String, dynamic>.from(h.records.first);
      await adminPress(tester, 'home-resource-edit-${row['ref']['id']}');
      await adminPress(tester, 'home-resource-save');
      expect(h.mutations.length, 1);
      expect(h.records.first, row);
      expect(adminKey('home-resource-mutation-saved'), findsOneWidget);
    },
  );
  testWidgets(
    'admin history loads beyond first page and frozen later target is updated',
    (tester) async {
      final h = ResourceAdminHarness();
      final template = h.records.first;
      h.records
        ..clear()
        ..addAll(
          List.generate(
            51,
            (index) => {
              ...template,
              'ref': {
                ...template['ref'] as Map,
                'id': (index + 1).toRadixString(16).padLeft(32, '0'),
              },
              'label': 'Record ${index + 1}',
              'order': index,
            },
          ),
        );
      await openAdmin(tester, h);
      for (var i = 0; i < 2; i++) {
        await tester.scrollUntilVisible(
          adminKey('home-resource-admin-load-more'),
          600,
          scrollable: find.byType(Scrollable).last,
          maxScrolls: 30,
        );
        await adminPress(tester, 'home-resource-admin-load-more');
      }
      final target = h.records.last;
      final id = target['ref']['id'];
      await tester.scrollUntilVisible(
        adminKey('home-resource-edit-$id'),
        600,
        scrollable: find.byType(Scrollable).last,
        maxScrolls: 30,
      );
      await adminPress(tester, 'home-resource-edit-$id');
      await tester.enterText(adminKey('home-resource-label'), 'Record renamed');
      await adminPress(tester, 'home-resource-save');
      expect(h.mutations.single.url.path, endsWith('/$id'));
      expect(h.records.last['label'], 'Record renamed');
      expect(h.records.first['label'], 'Record 1');
      expect(adminKey('home-resource-admin-load-more'), findsNothing);
      expect(adminKey('home-resource-mutation-saved'), findsOneWidget);
    },
  );

  testWidgets('member Core metadata never exposes management entry', (
    tester,
  ) async {
    final h = ResourceAdminHarness()..role = 'member';
    await h.mount(tester);
    await h.signIn();
    await flush(tester);
    expect(adminKey('home-resources-manage'), findsNothing);
    expect(h.mutations, isEmpty);
    expect(h.haReads, 0);
  });
  for (final kind in ['room', 'resource']) {
    testWidgets(
      'actual Core PIN flow creates renames reorders and deletes $kind metadata only',
      (tester) async {
        final h = ResourceAdminHarness();
        await openAdmin(tester, h, pin: '1234');
        await adminPress(tester, 'home-resource-admin-create');
        await adminPress(tester, 'home-resource-kind-$kind');
        await tester.enterText(adminKey('home-resource-label'), 'Yeni kayıt');
        await tester.enterText(adminKey('home-resource-order'), '7');
        await adminPress(tester, 'home-resource-save');
        expect(h.mutations.length, 1);
        expect(h.mutations.single.method, 'POST');
        expect(adminKey('home-resource-mutation-saved'), findsOneWidget);
        final saved = h.records.last;
        final id = saved['ref']['id'] as String;
        expect(saved['ref']['kind'], kind);
        expect(saved['label'], 'Yeni kayıt');
        await adminPress(tester, 'home-resource-edit-$id');
        await tester.enterText(
          adminKey('home-resource-label'),
          'Düzenlenen kayıt',
        );
        await tester.enterText(adminKey('home-resource-order'), '2');
        await adminPress(tester, 'home-resource-save');
        expect(h.mutations.length, 2);
        expect(h.mutations.last.method, 'PATCH');
        expect(h.records.last['label'], 'Düzenlenen kayıt');
        expect(h.records.last['order'], 2);
        await adminPress(tester, 'home-resource-delete-$id');
        expect(adminKey('home-resource-delete-confirmation'), findsOneWidget);
        expect(h.mutations.length, 2);
        await adminPress(tester, 'home-resource-confirm-delete');
        expect(h.mutations.length, 3);
        expect(h.mutations.last.method, 'DELETE');
        expect(adminKey('home-resource-mutation-deleted'), findsOneWidget);
        expect(h.records.any((record) => record['ref']['id'] == id), isFalse);
        expect(h.haReads, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'cancel discards metadata form and delete target without a mutation',
    (tester) async {
      final h = ResourceAdminHarness();
      await openAdmin(tester, h);
      await adminPress(tester, 'home-resource-admin-create');
      await tester.enterText(adminKey('home-resource-label'), 'Private draft');
      await adminPress(tester, 'home-resource-cancel-edit');
      expect(find.text('Private draft'), findsNothing);
      final id = h.records.first['ref']['id'] as String;
      await adminPress(tester, 'home-resource-delete-$id');
      await adminPress(tester, 'home-resource-cancel-edit');
      expect(adminKey('home-resource-delete-confirmation'), findsNothing);
      expect(h.mutations, isEmpty);
    },
  );
}
