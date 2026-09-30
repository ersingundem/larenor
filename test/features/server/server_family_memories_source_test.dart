import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/server/family_memories/data/server_family_memories_controller.dart';
import 'package:larenor/features/server/family_memories/domain/server_family_memory_models.dart';
import 'package:larenor/features/server/family_memories/presentation/server_family_memories_screen.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server_admin_test_support.dart';

const albumId = '11111111-1111-4111-8111-111111111111';
const serviceId = '33333333333333333333333333333333';

Map<String, Object?> sourceJson({bool bound = false}) => {
  'schemaVersion': 1,
  'accountId': adminId,
  'accountRevision': 1,
  'revision': bound ? 1 : 0,
  'membersRevision': 1,
  'canManage': true,
  'binding': bound ? bindingJson() : null,
  'albums': bound
      ? [
          {'albumId': albumId, 'title': 'Trip'},
        ]
      : [],
  'services': [
    {'serviceId': serviceId, 'serviceRevision': 7, 'name': 'Photos'},
  ],
  'members': [
    {'accountId': adminId, 'revision': 1, 'username': 'admin'},
  ],
};

Map<String, Object?> bindingJson() => {
  'serviceId': serviceId,
  'serviceRevision': 7,
  'allowedAlbumIds': [albumId],
  'faceSearchEnabled': false,
};

Map<String, Object?> snapshotJson() => {
  'schemaVersion': 1,
  'authority': {
    'coreId': '1' * 32,
    'homeId': '2' * 32,
    'accountId': adminId,
    'sessionId': sessionFamilyId,
    'membersRevision': 1,
  },
  'binding': bindingJson(),
  'memberIds': [adminId],
  'albums': [],
};

FamilyMemoriesLabels labels() => FamilyMemoriesLabels(
  title: 'Memories',
  searchHint: 'Search photos',
  search: 'Search',
  albums: 'Memory albums',
  results: 'Results',
  empty: 'No albums',
  createAlbum: 'Create album',
  albumNameHint: 'Album name',
  personal: 'Personal',
  shared: 'Shared',
  cancel: 'Cancel',
  save: 'Save',
  retry: 'Refresh',
  editAlbum: 'Edit',
  reconcile: 'Reconcile',
  delete: 'Delete',
  deleteConfirm: 'Delete album?',
  items: (count) => '$count photos',
  source: 'Photo source',
  sourceDescription: 'Choose specific albums.',
  sourceUnavailable: 'Verify Immich first.',
  sourceAlbumSelection: 'Allowed albums',
  sourceAccount: 'Account',
  sourceService: 'Choose service',
  faceConsent: 'Face tags',
  faceConsentDescription: 'Existing tags only.',
  disconnectSource: 'Remove access',
  disconnectConfirm: 'Keep originals?',
);

final class MemoryFixture extends AdminFixture {
  MemoryFixture() {
    respond = (request) async {
      if (!request.url.path.contains('/family-memories/')) {
        return defaultResponse(request);
      }
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final id = body['requestId'];
      if (request.url.path.endsWith('/sources/albums')) {
        expect(body['serviceId'], serviceId);
        expect(body['expectedServiceRevision'], 7);
        return this.json({
          'requestId': id,
          'albums': [
            {'albumId': albumId, 'title': 'Trip'},
          ],
        });
      }
      if (request.url.path.endsWith('/sources')) {
        if (request.method == 'PUT') {
          expect(body.keys.toSet(), {
            'schemaVersion',
            'requestId',
            'accountId',
            'expectedAccountRevision',
            'expectedRevision',
            'serviceId',
            'expectedServiceRevision',
            'allowedAlbumIds',
          });
          expect(body['accountId'], adminId);
          expect(body['expectedRevision'], 0);
          expect(body['allowedAlbumIds'], [albumId]);
          bound = true;
        }
        final value = this.json({
          'requestId': id,
          'source': sourceJson(bound: bound),
        });
        return pending == null ? value : pending!.future;
      }
      if (request.url.path.endsWith('/snapshot')) {
        snapshotCalls++;
        return this.json({'requestId': id, 'snapshot': snapshotJson()});
      }
      return http.Response('', 404);
    };
  }

  bool bound = false;
  int snapshotCalls = 0;
  Completer<http.Response>? pending;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'source metadata rejects duplicate albums and member service enumeration',
    () {
      final duplicate = sourceJson(bound: true)
        ..['albums'] = [
          {'albumId': albumId, 'title': 'Trip'},
          {'albumId': albumId, 'title': 'Trip'},
        ];
      expect(
        () => FamilyMemorySourceState.fromJson(duplicate),
        throwsA(isA<LarenorServerException>()),
      );
      final overbroad = sourceJson()..['canManage'] = false;
      expect(
        () => FamilyMemorySourceState.fromJson(overbroad),
        throwsA(isA<LarenorServerException>()),
      );
    },
  );

  test(
    'unbound source exposes setup without a failing snapshot request',
    () async {
      final fixture = MemoryFixture();
      await fixture.account.initialize();
      final controller = ServerFamilyMemoriesController(fixture.account);
      addTearDown(controller.dispose);
      addTearDown(fixture.account.dispose);
      await controller.load(current: () => true);
      expect(controller.source?.canManage, isTrue);
      expect(controller.snapshot, isNull);
      expect(controller.failure, isNull);
      expect(fixture.snapshotCalls, 0);
    },
  );

  test('late source reply cannot restore invalidated account state', () async {
    final fixture = MemoryFixture();
    await fixture.account.initialize();
    final controller = ServerFamilyMemoriesController(fixture.account);
    addTearDown(controller.dispose);
    addTearDown(fixture.account.dispose);
    fixture.pending = Completer<http.Response>();
    final loading = controller.load(current: () => true);
    await Future<void>.delayed(Duration.zero);
    controller.invalidate();
    final request = fixture.calls.last;
    final id = (jsonDecode(request.body) as Map<String, dynamic>)['requestId'];
    fixture.pending!.complete(
      fixture.json({'requestId': id, 'source': sourceJson(bound: true)}),
    );
    await loading;
    expect(controller.source, isNull);
    expect(controller.snapshot, isNull);
    expect(fixture.snapshotCalls, 0);
  });

  test('failed dependent refresh retires old selections atomically', () async {
    final fixture = MemoryFixture()..bound = true;
    await fixture.account.initialize();
    final controller = ServerFamilyMemoriesController(fixture.account);
    addTearDown(controller.dispose);
    addTearDown(fixture.account.dispose);
    await controller.load(current: () => true);
    expect(controller.snapshot, isNotNull);
    final previous = fixture.respond!;
    fixture.respond = (request) async {
      if (request.url.path.endsWith('/sources/face-consent')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final next = sourceJson(bound: true)
          ..['revision'] = 2
          ..['binding'] = (bindingJson()..['faceSearchEnabled'] = true);
        return fixture.json({'requestId': body['requestId'], 'source': next});
      }
      if (request.url.path.endsWith('/snapshot')) {
        return http.Response('', 503);
      }
      return previous(request);
    };
    await controller.faceConsent(true, current: () => true);
    expect(controller.needsRefresh, isTrue);
    expect(controller.snapshot, isNull);
    expect(controller.searchResults, isEmpty);
    expect(controller.source?.revision, 1);
    expect(controller.source?.binding?.faceSearchEnabled, isFalse);
    final calls = fixture.calls.length;
    await controller.search(
      serviceId: serviceId,
      serviceRevision: 7,
      query: 'Trip',
      albumIds: [albumId],
      current: () => true,
    );
    expect(fixture.calls.length, calls);
    expect(controller.needsRefresh, isTrue);
  });

  test(
    'source and snapshot binding drift is rejected before publication',
    () async {
      final fixture = MemoryFixture()..bound = true;
      final previous = fixture.respond!;
      fixture.respond = (request) async {
        if (request.url.path.endsWith('/snapshot')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final snapshot = snapshotJson()
            ..['binding'] = (bindingJson()..['serviceRevision'] = 8);
          return fixture.json({
            'requestId': body['requestId'],
            'snapshot': snapshot,
          });
        }
        return previous(request);
      };
      await fixture.account.initialize();
      final controller = ServerFamilyMemoriesController(fixture.account);
      addTearDown(controller.dispose);
      addTearDown(fixture.account.dispose);
      await controller.load(current: () => true);
      expect(controller.failure, 'stale_state');
      expect(controller.needsRefresh, isTrue);
      expect(controller.source, isNull);
      expect(controller.snapshot, isNull);
    },
  );

  testWidgets('closing another account settings reloads own source', (
    tester,
  ) async {
    const memberId = '44444444444444444444444444444444';
    final fixture = MemoryFixture()..bound = true;
    final previous = fixture.respond!;
    fixture.respond = (request) async {
      if (request.url.path.endsWith('/sources') && request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final other = body['accountId'] == memberId;
        final source = sourceJson(bound: true)
          ..['accountId'] = other ? memberId : adminId
          ..['members'] = [
            {'accountId': adminId, 'revision': 1, 'username': 'admin'},
            {'accountId': memberId, 'revision': 1, 'username': 'member'},
          ]
          ..['albums'] = [
            {'albumId': albumId, 'title': other ? 'Other album' : 'Trip'},
          ];
        return fixture.json({'requestId': body['requestId'], 'source': source});
      }
      return previous(request);
    };
    await fixture.account.initialize();
    final controller = ServerFamilyMemoriesController(fixture.account);
    addTearDown(controller.dispose);
    addTearDown(fixture.account.dispose);
    await tester.pumpWidget(
      CupertinoApp(
        home: ServerFamilyMemoriesScreen(
          controller: controller,
          labels: labels(),
          current: () => true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Search'), findsOneWidget);
    await tester.tap(find.byIcon(CupertinoIcons.settings));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CupertinoListTile, 'Account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('member'));
    await tester.pumpAndSettle();
    expect(controller.isOwnSource, isFalse);
    expect(controller.snapshot, isNull);
    expect(find.text('Other album'), findsOneWidget);
    await tester.tap(find.byIcon(CupertinoIcons.settings));
    await tester.pumpAndSettle();
    expect(controller.isOwnSource, isTrue);
    expect(controller.source?.albums.single.title, 'Trip');
    expect(controller.snapshot, isNotNull);
    expect(find.text('Search'), findsOneWidget);
    expect(find.text('Other album'), findsNothing);
  });

  testWidgets(
    'admin chooses actual source and album before granting and searching',
    (tester) async {
      final fixture = MemoryFixture();
      await fixture.account.initialize();
      final controller = ServerFamilyMemoriesController(fixture.account);
      addTearDown(controller.dispose);
      addTearDown(fixture.account.dispose);
      await tester.pumpWidget(
        CupertinoApp(
          home: ServerFamilyMemoriesScreen(
            controller: controller,
            labels: labels(),
            current: () => true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Photo source'), findsOneWidget);
      expect(find.text('Search'), findsNothing);
      await tester.tap(
        find.widgetWithText(CupertinoListTile, 'Choose service'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Photos'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Trip'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(CupertinoButton, 'Save'));
      await tester.pumpAndSettle();
      expect(fixture.bound, isTrue);
      expect(controller.snapshot, isNotNull);
      expect(find.text('Search'), findsOneWidget);
      expect(
        fixture.calls.where(
          (request) =>
              request.method == 'PUT' && request.url.path.endsWith('/sources'),
        ),
        hasLength(1),
      );
    },
  );
}
