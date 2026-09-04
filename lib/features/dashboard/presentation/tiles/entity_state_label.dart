import 'package:flutter/cupertino.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../ha_client/data/models/ha_entity.dart';

/// Turns a Home Assistant state string into something a person would read.
///
/// HA states arrive as raw English tokens (`off`, `idle`, `disarmed`,
/// `not_home`) regardless of app language, so a tile that printed
/// `entity.state` directly showed a mix of translated and untranslated
/// text side by side in the same grid. Scenes are worse: their state is
/// the timestamp they were last activated, which is meaningless on a tile.
String entityStateLabel(BuildContext context, HaEntity entity) {
  final l10n = AppLocalizations.of(context);

  // A scene's state is its last-activated timestamp — never worth showing.
  if (entity.domain == 'scene') return l10n.entityStateScene;

  // A numeric reading with a unit beats any state word.
  final unit = entity.attributes['unit_of_measurement'] as String?;
  if (unit != null && double.tryParse(entity.state) != null) {
    return '${entity.state}$unit';
  }

  final label = _labelFor(l10n, entity.state);
  if (label != null) return label;

  // Anything unrecognised is shown as-is rather than hidden, so an
  // unusual integration still tells you something.
  return entity.state;
}

String? _labelFor(AppLocalizations l10n, String state) => switch (state) {
  'on' => l10n.entityStateOn,
  'off' => l10n.entityStateOff,
  'open' => l10n.entityStateOpen,
  'closed' => l10n.entityStateClosed,
  'opening' => l10n.entityStateOpening,
  'closing' => l10n.entityStateClosing,
  'locked' => l10n.entityStateLocked,
  'unlocked' => l10n.entityStateUnlocked,
  'home' => l10n.entityStateHome,
  'not_home' => l10n.entityStateAway,
  'idle' => l10n.entityStateIdle,
  'playing' => l10n.entityStatePlaying,
  'paused' => l10n.entityStatePaused,
  'standby' => l10n.entityStateStandby,
  'disarmed' => l10n.entityStateDisarmed,
  'armed_home' => l10n.entityStateArmedHome,
  'armed_away' => l10n.entityStateArmedAway,
  'armed_night' => l10n.entityStateArmedNight,
  'triggered' => l10n.entityStateTriggered,
  'arming' => l10n.entityStateArming,
  'pending' => l10n.entityStatePending,
  'cleaning' => l10n.entityStateCleaning,
  'docked' => l10n.entityStateDocked,
  'returning' => l10n.entityStateReturning,
  'heat' || 'heating' => l10n.entityStateHeating,
  'cool' || 'cooling' => l10n.entityStateCooling,
  'dry' || 'drying' => l10n.entityStateDrying,
  'fan_only' => l10n.entityStateFanOnly,
  'auto' => l10n.entityStateAuto,
  'detected' => l10n.entityStateDetected,
  'clear' => l10n.entityStateClear,
  'unavailable' => l10n.entityStateUnavailable,
  'unknown' => l10n.commonUnknown,
  _ => null,
};
