import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:larenor/core/home_data_scope.dart';
import 'package:larenor/features/dashboard/data/dashboard_repository.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/features/home_scope/data/core_layout_archive_codec.dart';
import 'package:larenor/features/home_scope/data/core_layout_archive_controller.dart';
import 'package:larenor/features/home_scope/presentation/core_layout_archive_file_access.dart';

import '../../integration_test/support/synthetic_core_archive_files.dart';

const password = 'Synthetic archive passphrase 2026';
const archived = DashboardLayout(rooms: [DashboardRoom(id: 'saved-room', name: 'Saved room')]);
const replacement = DashboardLayout(rooms: [DashboardRoom(id: 'target-room', name: 'Target room')]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final scope = HomeDataScope.fromJson({'coreId': 'a' * 32, 'homeId': 'b' * 32, 'userId': 'fixture-core-user-id'});
  setUp(() => SharedPreferences.setMockInitialValues({'dashboard_layout': 'legacy-sentinel', 'unrelated': 'kept'}));

  test('save and every read keep independent byte ownership', () async {
    final files = SyntheticCoreArchiveFiles();
    final bytes = Uint8List.fromList([1, 2, 3]);
    final result = await files.save(bytes);
    bytes[0] = 9;
    expect(result, Uri.parse('memory:core-room-archive'));
    expect(files.savedCiphertext, [1, 2, 3]);
    final returned = files.savedCiphertext!;
    returned[1] = 9;
    expect(files.savedCiphertext, [1, 2, 3]);
    expect(files.saves, 1);
    expect(files.picks, 0);
  });

  test('pick queue freezes inputs and consumes one explicit selection', () async {
    final files = SyntheticCoreArchiveFiles();
    final bytes = Uint8List.fromList([1, 2, 3]);
    files.queuePick(bytes);
    bytes[0] = 9;
    final picked = (await files.pick())!;
    expect(picked, [1, 2, 3]);
    picked[1] = 9;
    expect(await files.pick(), isNull);
    expect(files.picks, 2);
    expect(files.saves, 0);
  });

  test('cancel never reuses saved ciphertext or the next queued selection', () async {
    final files = SyntheticCoreArchiveFiles();
    await files.save(Uint8List.fromList([3]));
    files.queuePick(null);
    files.queuePick(Uint8List.fromList([4]));
    expect(await files.pick(), isNull);
    expect(await files.pick(), [4]);
    expect(await files.pick(), isNull);
    expect(files.savedCiphertext, [3]);
  });

  test('pending selections are bounded without dropping the first selection', () async {
    final files = SyntheticCoreArchiveFiles();
    for (var i = 0; i < 4; i++) files.queuePick(Uint8List.fromList([i]));
    expect(() => files.queuePick(Uint8List.fromList([9])), throwsA(isA<CoreLayoutArchiveFileException>()));
    for (var i = 0; i < 4; i++) expect(await files.pick(), [i]);
    expect(await files.pick(), isNull);
  });

  for (final size in [0, CoreLayoutArchiveFileAccess.maxFileBytes + 1]) {
    test('invalid $size-byte save does not replace existing output', () async {
      final files = SyntheticCoreArchiveFiles();
      await files.save(Uint8List.fromList([7]));
      await expectLater(files.save(Uint8List(size)), throwsA(isA<CoreLayoutArchiveFileException>()));
      expect(files.savedCiphertext, [7]);
      expect(files.saves, 1);
    });
    test('invalid $size-byte pick is not enqueued', () async {
      final files = SyntheticCoreArchiveFiles();
      expect(() => files.queuePick(Uint8List(size)), throwsA(isA<CoreLayoutArchiveFileException>()));
      expect(await files.pick(), isNull);
    });
  }

  test('real codec and scoped controller require explicit apply and preserve legacy data', () async {
    final files = SyntheticCoreArchiveFiles();
    final repository = DashboardRepository.core(scope: scope, isCurrent: () => true);
    final controller = CoreLayoutArchiveController(destination: repository, isCurrent: () => true);
    addTearDown(controller.close);
    const codec = CoreLayoutArchiveCodec();
    await repository.save(archived);
    final captured = await controller.capture();
    await files.save(await codec.encrypt(captured, password));
    final ciphertext = files.savedCiphertext!;
    final wire = utf8.decode(ciphertext);
    expect(wire, isNot(contains('Saved room')));
    expect(wire, isNot(contains(password)));
    expect(jsonDecode(wire)['format'], 'larenor-core-layout-archive');
    await repository.save(replacement);
    final before = await repository.readSnapshot();
    files.queuePick(null);
    expect(await files.pick(), isNull);
    expect((await repository.readSnapshot()).fingerprint, before.fingerprint);
    files.queuePick(ciphertext);
    final picked = (await files.pick())!;
    await expectLater(codec.decrypt(picked, 'Wrong archive passphrase 2026'), throwsA(isA<CoreLayoutArchiveCodecException>()));
    expect((await repository.readSnapshot()).fingerprint, before.fingerprint);
    final decoded = await codec.decrypt(picked, password);
    final preview = await controller.preview(decoded);
    expect(preview.currentRoomNames, ['Target room']);
    expect(preview.archivedRoomNames, ['Saved room']);
    // Cancelling confirmation means no apply call; preview alone never writes.
    expect((await repository.readSnapshot()).fingerprint, before.fingerprint);
    await controller.apply(preview);
    final reopened = DashboardRepository.core(scope: scope, isCurrent: () => true);
    final restored = await reopened.readSnapshot();
    expect(restored.layout, archived);
    expect(restored.revision, before.revision + 1);
    final preferences = await SharedPreferences.getInstance();
    await preferences.reload();
    expect(preferences.getString('dashboard_layout'), 'legacy-sentinel');
    expect(preferences.getString('unrelated'), 'kept');
    expect(preferences.getKeys(), {'dashboard_layout', 'unrelated', scope.storageKey});
    await expectLater(controller.apply(preview), throwsA(isA<DashboardStorageException>()));
  });
}
