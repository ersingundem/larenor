import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/remote_access/vnc/vnc_engine.dart';
import 'package:larenor/features/remote_access/vnc/vnc_models.dart';

import 'vnc_models_test.dart' show profile;

void main() {
  test(
    'unsupported engine reports no capability and cannot negotiate',
    () async {
      final engine = UnsupportedVncEngine();
      final capabilities = await engine.capabilities(isCurrent: () => true);
      expect(capabilities.availability, VncEngineAvailability.unavailable);
      expect(capabilities.canConnect, isFalse);
      await expectLater(
        engine.negotiate(profile, isCurrent: () => true),
        throwsA(
          isA<VncFailure>().having(
            (value) => value.code,
            'code',
            'engine_unavailable',
          ),
        ),
      );
    },
  );

  test('unsupported engine rejects retired capability checks', () async {
    final engine = UnsupportedVncEngine();
    await expectLater(
      engine.capabilities(isCurrent: () => false),
      throwsA(
        isA<VncFailure>().having((value) => value.code, 'code', 'retired'),
      ),
    );
  });
}
