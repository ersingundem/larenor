// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';

import 'jellyfin_config.dart';
import 'legacy_jellyfin_track_preferences_preview.dart';

enum LegacyJellyfinTrackPreferencesMigrationPhase {
  initial,
  loading,
  ready,
  applying,
  applied,
  failed,
  unavailable,
  dismissed,
  retired,
}

@immutable
final class LegacyJellyfinTrackPreferencesMigrationState {
  const LegacyJellyfinTrackPreferencesMigrationState({
    required this.phase,
    this.audioLanguage,
    this.subtitleLanguage,
  });

  const LegacyJellyfinTrackPreferencesMigrationState.initial()
    : this(phase: LegacyJellyfinTrackPreferencesMigrationPhase.initial);

  final LegacyJellyfinTrackPreferencesMigrationPhase phase;
  final String? audioLanguage;
  final String? subtitleLanguage;

  @override
  String toString() => 'Legacy track preference migration: ${phase.name}';
}

/// Owns one exact preview/confirmation opportunity for a live route authority.
///
/// The direct Jellyfin configuration remains private. Public state contains
/// only normalized language choices and a bounded phase.
final class LegacyJellyfinTrackPreferencesMigrationController
    extends ChangeNotifier {
  LegacyJellyfinTrackPreferencesMigrationController({
    required LegacyJellyfinTrackPreferencesMigrationGateway migration,
    required JellyfinConfig config,
    required bool Function() isCurrent,
    Listenable? lifecycle,
  }) : _migration = migration,
       _config = config,
       _isCurrent = isCurrent,
       _lifecycle = lifecycle {
    lifecycle?.addListener(_lifecycleChanged);
  }

  final LegacyJellyfinTrackPreferencesMigrationGateway _migration;
  final JellyfinConfig _config;
  final bool Function() _isCurrent;
  final Listenable? _lifecycle;
  int _operation = 0;
  bool _disposed = false;
  LegacyJellyfinTrackPreferencesMigrationReceipt? _receipt;
  LegacyJellyfinTrackPreferencesMigrationState _state =
      const LegacyJellyfinTrackPreferencesMigrationState.initial();

  LegacyJellyfinTrackPreferencesMigrationState get state => _state;

  bool _authority() {
    if (_disposed) return false;
    try {
      return _isCurrent();
    } catch (_) {
      return false;
    }
  }

  bool _current(int operation) =>
      !_disposed && operation == _operation && _authority();

  void _publish(LegacyJellyfinTrackPreferencesMigrationState value) {
    if (_disposed) return;
    _state = value;
    notifyListeners();
  }

  Future<void> start() async {
    if (_disposed ||
        !const {
          LegacyJellyfinTrackPreferencesMigrationPhase.initial,
          LegacyJellyfinTrackPreferencesMigrationPhase.unavailable,
        }.contains(_state.phase)) {
      return;
    }
    if (!_authority()) {
      retire();
      return;
    }
    final operation = ++_operation;
    _publish(
      const LegacyJellyfinTrackPreferencesMigrationState(
        phase: LegacyJellyfinTrackPreferencesMigrationPhase.loading,
      ),
    );
    try {
      final receipt = await _migration.prepare(
        _config,
        isCurrent: () => _current(operation),
      );
      if (!_current(operation)) return;
      if (receipt == null) {
        _publish(
          const LegacyJellyfinTrackPreferencesMigrationState(
            phase: LegacyJellyfinTrackPreferencesMigrationPhase.unavailable,
          ),
        );
        return;
      }
      _receipt = receipt;
      _publish(
        LegacyJellyfinTrackPreferencesMigrationState(
          phase: LegacyJellyfinTrackPreferencesMigrationPhase.ready,
          audioLanguage: receipt.audioLanguage,
          subtitleLanguage: receipt.subtitleLanguage,
        ),
      );
    } catch (_) {
      if (_current(operation)) {
        _publish(
          const LegacyJellyfinTrackPreferencesMigrationState(
            phase: LegacyJellyfinTrackPreferencesMigrationPhase.unavailable,
          ),
        );
      }
    }
  }

  Future<void> confirm() async {
    final receipt = _receipt;
    if (_disposed ||
        receipt == null ||
        !const {
          LegacyJellyfinTrackPreferencesMigrationPhase.ready,
          LegacyJellyfinTrackPreferencesMigrationPhase.failed,
        }.contains(_state.phase)) {
      return;
    }
    if (!_authority()) {
      retire();
      return;
    }
    final operation = ++_operation;
    _publish(
      LegacyJellyfinTrackPreferencesMigrationState(
        phase: LegacyJellyfinTrackPreferencesMigrationPhase.applying,
        audioLanguage: receipt.audioLanguage,
        subtitleLanguage: receipt.subtitleLanguage,
      ),
    );
    try {
      final saved = await _migration.confirm(
        _config,
        receipt,
        isCurrent: () => _current(operation),
      );
      if (!_current(operation)) return;
      _receipt = null;
      _publish(
        LegacyJellyfinTrackPreferencesMigrationState(
          phase: LegacyJellyfinTrackPreferencesMigrationPhase.applied,
          audioLanguage: saved.audioLanguage,
          subtitleLanguage: saved.subtitleLanguage,
        ),
      );
    } catch (_) {
      if (_current(operation)) {
        _publish(
          LegacyJellyfinTrackPreferencesMigrationState(
            phase: LegacyJellyfinTrackPreferencesMigrationPhase.failed,
            audioLanguage: receipt.audioLanguage,
            subtitleLanguage: receipt.subtitleLanguage,
          ),
        );
      }
    }
  }

  void cancel() {
    if (_disposed) return;
    _operation++;
    final receipt = _receipt;
    _receipt = null;
    if (receipt != null) _migration.cancel(receipt);
    _publish(
      const LegacyJellyfinTrackPreferencesMigrationState(
        phase: LegacyJellyfinTrackPreferencesMigrationPhase.dismissed,
      ),
    );
  }

  void _lifecycleChanged() {
    if (!_authority()) retire();
  }

  void retire() {
    if (_disposed ||
        _state.phase == LegacyJellyfinTrackPreferencesMigrationPhase.retired) {
      return;
    }
    _operation++;
    final receipt = _receipt;
    _receipt = null;
    if (receipt != null) _migration.cancel(receipt);
    _publish(
      const LegacyJellyfinTrackPreferencesMigrationState(
        phase: LegacyJellyfinTrackPreferencesMigrationPhase.retired,
      ),
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _lifecycle?.removeListener(_lifecycleChanged);
    _operation++;
    final receipt = _receipt;
    _receipt = null;
    if (receipt != null) _migration.cancel(receipt);
    _disposed = true;
    super.dispose();
  }

  @override
  String toString() => 'Legacy Jellyfin track preference migration controller';
}
