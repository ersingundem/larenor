import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/live_tv/data/server_live_tv_api.dart';

class _Store implements ServerSessionPersistence {
  @override
  Future<ServerSession?> read() async => null;

  @override
  Future<void> write(ServerSession? value) async {}
}

void main() {
  final url = Platform.environment['LARENOR_F23_CORE_URL'];
  setUpAll(() => HttpOverrides.global = null);
  test(
    'actual Client configures Jellyfin guide and schedules and cancels timer',
    () async {
      final account = ServerAccountController(store: _Store());
      addTearDown(account.dispose);
      await account.signIn(
        baseUrl: url!,
        username: 'admin',
        password: 'Synthetic new password 2026',
        deviceName: 'Live TV gate',
      );
      expect(account.failure, isNull);
      await account.withSession((transport, session) async {
        final ids = <String>['4' * 32, '5' * 32, '6' * 32].iterator;
        final api = ServerLiveTvApi(
          transport,
          session,
          requestId: () {
            expect(ids.moveNext(), isTrue);
            return ids.current;
          },
        );
        final options = await api.sourceOptions(current: () => true);
        expect(options.expectedRevision, 0);
        expect(options.services, hasLength(1));
        expect(options.services.single.name, 'Jellyfin Live TV');
        final source = await api.configureJellyfin(
          expectedRevision: 0,
          service: options.services.single,
          providerKind: 'iptv',
          timeZone: 'Europe/Istanbul',
          quotaBytes: 10737418240,
          current: () => true,
        );
        expect(source.programmes, hasLength(1));
        await api.schedule(
          source,
          source.programmes.single,
          current: () => true,
        );
        final scheduled = await api.read(current: () => true);
        expect(scheduled.recordings, hasLength(1));
        expect(scheduled.recordings.single.state.name, 'scheduled');
        await api.cancel(scheduled.recordings.single, current: () => true);
        final cancelled = await api.read(current: () => true);
        expect(cancelled.recordings.single.state.name, 'cancelled');
      });
    },
    skip: url == null ? 'Requires explicit isolated normal Core runner' : false,
  );
}
