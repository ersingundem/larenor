import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_config.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_track_preferences_store.dart';
import 'package:larenor/features/media/jellyfin/data/legacy_jellyfin_track_preferences_controller.dart';
import 'package:larenor/features/media/jellyfin/data/legacy_jellyfin_track_preferences_preview.dart';
import 'package:larenor/features/media/jellyfin/domain/jellyfin_track_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _config = JellyfinConfig(
  baseUrl: 'https://private-jellyfin.invalid/root',
  userId: 'private-user-id',
  accessToken: 'private-access-token',
  deviceId: 'private-device-id',
);

String _legacyKey(JellyfinConfig config) {
  final scope = sha256.convert(
    utf8.encode('${config.baseUrl}\u0000${config.userId}'),
  );
  return 'jellyfin_track_languages_v1_$scope';
}

final class _Lifecycle extends ChangeNotifier {
  bool current = true;

  void replace() {
    current = false;
    notifyListeners();
  }
}

final class _DelayedGateway
    implements LegacyJellyfinTrackPreferencesMigrationGateway {
  _DelayedGateway(this.delegate);

  final LegacyJellyfinTrackPreferencesMigration delegate;
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<LegacyJellyfinTrackPreferencesMigrationReceipt?> prepare(
    JellyfinConfig config, {
    required bool Function() isCurrent,
  }) => delegate.prepare(config, isCurrent: isCurrent);

  @override
  Future<JellyfinTrackPreferenceRecord> confirm(
    JellyfinConfig config,
    LegacyJellyfinTrackPreferencesMigrationReceipt receipt, {
    required bool Function() isCurrent,
  }) async {
    if (!started.isCompleted) started.complete();
    await release.future;
    return delegate.confirm(config, receipt, isCurrent: isCurrent);
  }

  @override
  void cancel(LegacyJellyfinTrackPreferencesMigrationReceipt receipt) =>
      delegate.cancel(receipt);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('publishes only normalized retained choices and cancel keeps storage', () async {
    final raw = jsonEncode({'version': 1, 'audio': 'tur', 'subtitle': 'off'});
    SharedPreferences.setMockInitialValues({_legacyKey(_config): raw});
    final lifecycle = _Lifecycle();
    final controller = LegacyJellyfinTrackPreferencesMigrationController(
      migration: LegacyJellyfinTrackPreferencesMigration(
        core: JellyfinTrackPreferencesStore(),
      ),
      config: _config,
      isCurrent: () => lifecycle.current,
      lifecycle: lifecycle,
    );
    addTearDown(controller.dispose);

    await controller.start();

    expect(
      controller.state.phase,
      LegacyJellyfinTrackPreferencesMigrationPhase.ready,
    );
    expect(controller.state.audioLanguage, 'tr');
    expect(controller.state.subtitleLanguage, 'off');
    final public = '${controller.state} $controller';
    expect(public, isNot(contains(_config.baseUrl)));
    expect(public, isNot(contains(_config.userId)));
    expect(public, isNot(contains(_config.accessToken)));

    controller.cancel();

    expect(
      controller.state.phase,
      LegacyJellyfinTrackPreferencesMigrationPhase.dismissed,
    );
    expect(
      (await SharedPreferences.getInstance()).getString(_legacyKey(_config)),
      raw,
    );
  });

  test('replacement during confirm retires stale result and keeps legacy source', () async {
    final raw = jsonEncode({'version': 1, 'audio': 'en', 'subtitle': null});
    SharedPreferences.setMockInitialValues({_legacyKey(_config): raw});
    final lifecycle = _Lifecycle();
    final gateway = _DelayedGateway(
      LegacyJellyfinTrackPreferencesMigration(
        core: JellyfinTrackPreferencesStore(),
      ),
    );
    final controller = LegacyJellyfinTrackPreferencesMigrationController(
      migration: gateway,
      config: _config,
      isCurrent: () => lifecycle.current,
      lifecycle: lifecycle,
    );
    addTearDown(controller.dispose);
    await controller.start();

    final confirming = controller.confirm();
    await gateway.started.future;
    lifecycle.replace();
    gateway.release.complete();
    await confirming;

    expect(
      controller.state.phase,
      LegacyJellyfinTrackPreferencesMigrationPhase.retired,
    );
    expect(
      (await SharedPreferences.getInstance()).getString(_legacyKey(_config)),
      raw,
    );
  });
}
