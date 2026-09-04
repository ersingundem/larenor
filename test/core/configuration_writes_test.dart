import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/configuration_writes.dart';

void main() {
  test(
    'snapshot waits for whole credential record and nested writes',
    () async {
      final nextField = Completer<void>();
      final fields = <String, String>{};
      final write = ConfigurationWrites.run(() async {
        fields['server'] = 'new-server';
        await nextField.future;
        await ConfigurationWrites.run(
          () async => fields['token'] = 'new-token',
        );
      });
      final snapshot = ConfigurationWrites.run(() async => {...fields});
      await Future<void>.delayed(Duration.zero);
      expect(fields.keys, ['server']);
      nextField.complete();
      await write;
      expect(await snapshot, {'server': 'new-server', 'token': 'new-token'});
    },
  );

  test('one failed write does not poison later recovery work', () async {
    final failed = ConfigurationWrites.run<void>(
      () async => throw StateError('write'),
    );
    final recovered = ConfigurationWrites.run(() async => true);
    await expectLater(failed, throwsStateError);
    expect(await recovered, isTrue);
  });
}
