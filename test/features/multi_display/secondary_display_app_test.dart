import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/multi_display/domain/dual_display_session.dart';
import 'package:larenor/features/multi_display/presentation/secondary_display_app.dart';

const channel = MethodChannel('com.ersingundem.larenor/f52-secondary-test');
const codec = StandardMethodCodec();

PublicCoreStatusSnapshot snapshot(int revision, {int load = 12}) =>
    PublicCoreStatusSnapshot(
      snapshotRevision: revision,
      observedAtMs: 1000,
      expiresAtMs: 16000,
      systemLoadPercent: load,
      processMemoryMiB: 128,
      dataDiskFreeBytes: 400,
      dataDiskTotalBytes: 1000,
      processUptimeSeconds: 3660,
    );

Future<Object?> nativeUpdate(PublicCoreStatusSnapshot value) async {
  final completer = Completer<ByteData?>();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(
          MethodCall('publicSnapshot', value.toPublicMessage()),
        ),
        completer.complete,
      );
  return codec.decodeEnvelope((await completer.future)!);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('public Core task shows only bounded actual health metrics', (
    tester,
  ) async {
    await tester.pumpWidget(
      SecondaryDisplayApp(
        routeId: 'core.status',
        initialSnapshot: snapshot(101),
        channel: channel,
      ),
    );
    expect(find.text('Core online'), findsOne);
    expect(find.text('12%'), findsOne);
    expect(find.text('128 MiB'), findsOne);
    expect(find.text('60%'), findsOne);
    expect(find.text('1h 1m'), findsOne);
    expect(find.textContaining('account'), findsNothing);
    expect(find.textContaining('media'), findsNothing);
    expect(find.textContaining('token'), findsNothing);
  });

  testWidgets(
    'new public snapshot updates and local freshness expiry hides it',
    (tester) async {
      var now = DateTime.utc(2026);
      await tester.pumpWidget(
        SecondaryDisplayApp(
          routeId: 'core.status',
          initialSnapshot: snapshot(101),
          channel: channel,
          now: () => now,
        ),
      );
      expect(await nativeUpdate(snapshot(102, load: 27)), isTrue);
      await tester.pump();
      expect(find.text('27%'), findsOne);

      now = now.add(const Duration(seconds: 16));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('secondary-core-stale')), findsOne);
      expect(find.text('Core online'), findsNothing);
    },
  );

  testWidgets('unknown route is an explicit unavailable state', (tester) async {
    await tester.pumpWidget(
      const SecondaryDisplayApp(
        routeId: null,
        initialSnapshot: null,
        channel: channel,
      ),
    );
    expect(find.text('External task unavailable'), findsOne);
  });
}
