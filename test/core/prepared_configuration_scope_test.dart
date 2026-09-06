import 'dart:convert';
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/configuration_scope.dart';
import 'package:larenor/core/configuration_writes.dart';
import 'package:larenor/features/backup/data/backup_repository.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';

import '../features/backup/backup_test_storage.dart';
import '../features/backup/prepared_restore_test.dart' as f;

class _Storage extends MemoryBackupStorage {
  _Storage() : super(preferences: {'appearance': 'dark'});
  bool failInitialAck = false;
  @override
  Future<void> writeSecret(String key, String? value) async {
    await super.writeSecret(key, value);
    if (failInitialAck && key == 'backup_restore_journal_v2' && value != null) {
      failReads = true;
      throw StateError('private-platform-error');
    }
  }
}

class _Harness {
  _Harness(this.storage);
  final _Storage storage;
  final access = f.TestRestoreAccess();
  final errors = <Object>[];
  int created = 0, disposed = 0;
  late PreparedBackupRestore prepared;
  Future<void> mount(WidgetTester tester) async {
    prepared = await f.prepare(BackupRepository(storage: storage), access);
    final config = Provider<String>((ref) {
      created++;
      ref.onDispose(() {
        disposed++;
        access.live = false;
      });
      return storage.preferences['appearance'] as String;
    });
    await tester.pumpWidget(
      ConfigurationScope(
        child: CupertinoApp(
          home: Consumer(
            builder: (context, ref, _) => Column(
              children: [
                Text(ref.watch(config)),
                CupertinoButton(
                  child: const Text('Restore'),
                  onPressed: () async {
                    try {
                      await ConfigurationScope.restorePrepared(
                        context,
                        prepared: prepared,
                        progressLabel: 'Restoring',
                        failureLabel: 'Recovery required',
                        continueLabel: 'Retry recovery',
                      );
                    } catch (error) {
                      errors.add(error);
                    }
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  testWidgets(
    'prepared handoff owns legitimate UI disposal before persistence and fresh provider reload',
    (tester) async {
      final h = _Harness(_Storage());
      await h.mount(tester);
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      expect(h.errors, isEmpty);
      expect(h.disposed, 1);
      expect(h.created, 2);
      expect(h.storage.preferences['appearance'], 'light');
      expect(find.text('light'), findsOneWidget);
      expect(h.storage.secrets, isEmpty);
    },
  );
  testWidgets(
    'queued stale approval never disposes providers or writes an intent',
    (tester) async {
      final h = _Harness(_Storage());
      await h.mount(tester);
      final finish = Completer<void>();
      final queued = ConfigurationWrites.run(() => finish.future);
      await tester.tap(find.text('Restore'));
      await tester.pump();
      expect(h.disposed, 0);
      h.access.live = false;
      finish.complete();
      await queued;
      await tester.pumpAndSettle();
      expect(h.disposed, 0);
      expect(h.storage.writes, isEmpty);
      expect(h.errors, hasLength(1));
      expect(h.errors.single, isA<BackupException>());
    },
  );
  testWidgets(
    'uncertain initial ACK cannot reopen providers until exact recovery succeeds',
    (tester) async {
      final h = _Harness(_Storage());
      await h.mount(tester);
      h.storage.failInitialAck = true;
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      expect(find.text('Recovery required'), findsOneWidget);
      expect(h.created, 1);
      expect(h.disposed, 1);
      expect(find.textContaining('private-platform'), findsNothing);
      await tester.tap(find.text('Retry recovery'));
      await tester.pumpAndSettle();
      expect(h.created, 1);
      expect(find.text('Recovery required'), findsOneWidget);
      h.storage.failReads = false;
      h.storage.failInitialAck = false;
      await tester.tap(find.text('Retry recovery'));
      await tester.pumpAndSettle();
      expect(h.created, 2);
      expect(find.text('dark'), findsOneWidget);
      expect(h.storage.secrets, isEmpty);
      expect(h.storage.writes.where((v) => v.startsWith('pref:')), isEmpty);
    },
  );
  testWidgets(
    'failed handoff Continue cannot adopt a valid replacement transaction',
    (tester) async {
      final other = MemoryBackupStorage(preferences: {'appearance': 'dark'});
      await f.apply(
        await f.prepare(
          BackupRepository(storage: other),
          f.TestRestoreAccess(),
          f.restoreFixture({'appearance': 'system'}),
        ),
      );
      final replacement = other.durableImages
          .firstWhere((i) => i.secrets['backup_restore_journal_v2'] != null)
          .secrets['backup_restore_journal_v2']!;
      expect((jsonDecode(replacement) as Map)['phase'], 'applying');
      final h = _Harness(_Storage());
      await h.mount(tester);
      h.storage.failInitialAck = true;
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      expect(find.text('Recovery required'), findsOneWidget);
      h.storage.failReads = false;
      h.storage.failInitialAck = false;
      h.storage.secrets['backup_restore_journal_v2'] = replacement;
      h.storage.preferences['appearance'] = 'system';
      h.storage.writes.clear();
      await tester.tap(find.text('Retry recovery'));
      await tester.pumpAndSettle();
      expect(h.created, 1);
      expect(find.text('Recovery required'), findsOneWidget);
      expect(h.storage.secrets['backup_restore_journal_v2'], replacement);
      expect(h.storage.preferences['appearance'], 'system');
      expect(h.storage.writes, isEmpty);
    },
  );
}
