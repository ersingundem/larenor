import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../ha_client/data/models/ha_entity.dart';
import '../../../wellbeing/providers/wellbeing_privacy_providers.dart';
import '../../../ha_tools/presentation/ha_session_guard.dart';
import '../../presentation/dashboard_edit_guard.dart';
import '../../../ha_tools/presentation/ha_actions_screen.dart';
import '../../../health/providers/ha_actions.dart';
import '../../../../shared/widgets/action_status_indicator.dart';

/// Native controls for a current entity snapshot. Callers should keep light
/// and simple on/off controls alongside this widget. Services must exist in
/// the live catalog, and feature flags/attributes constrain entity support.
/// Flag definitions: home-assistant/core components/{domain}/const.py.
class EntityControls extends ConsumerStatefulWidget {
  const EntityControls({super.key, required this.entity, this.sourceCurrent});
  final bool Function()? sourceCurrent;
  final HaEntity entity;

  @override
  ConsumerState<EntityControls> createState() => _EntityControlsState();
}

class _EntityControlsState extends HaSessionState<EntityControls> {
  bool _busy = false, _sending = false;
  Route<dynamic>? _modal;
  final _drafts = <String, double>{};
  String? _error;
  static const _domains = {
    'climate',
    'cover',
    'lock',
    'fan',
    'number',
    'input_number',
    'select',
    'input_select',
    'media_player',
  };

  @override
  bool sourceSessionCurrent() => widget.sourceCurrent?.call() ?? true;
  HaEntity? get _currentEntity {
    if (!haSessionAvailable) return null;
    final states = ref.read(publicHaEntitiesProvider);
    return states.isLoading || states.hasError
        ? null
        : states.value?[widget.entity.entityId];
  }

  HaEntity get _entity => _currentEntity ?? widget.entity;
  @override
  void clearPendingInteraction() {
    _drafts.clear();
    _error = null;
    _busy = false;
    _sending = false;
    final route = _modal;
    _modal = null;
    if (route?.isActive == true) route!.navigator?.removeRoute(route);
  }

  bool _current(HaSessionLease lease, String entityId) =>
      isHaSessionCurrent(lease) &&
      entityId == widget.entity.entityId &&
      _currentEntity != null;

  Map<String, dynamic> get _attributes => _entity.attributes;
  AppLocalizations get _l10n => AppLocalizations.of(context);
  bool get _disabled =>
      _busy ||
      !haSessionAvailable ||
      _currentEntity == null ||
      _entity.state == 'unavailable';
  bool _feature(int flag) {
    final value = _attributes['supported_features'];
    return value is int && value >= 0 && value & flag != 0;
  }

  bool _service(String service) {
    final catalog = ref.read(haActionsProvider);
    return !catalog.isLoading &&
        !catalog.hasError &&
        (catalog.value?.any(
              (action) =>
                  action.domain == _entity.domain && action.service == service,
            ) ??
            false);
  }

  List<String> _options(String key) => (_attributes[key] is List)
      ? (_attributes[key] as List).whereType<String>().toSet().toList()
      : [];

  static double? _number(dynamic value) {
    final result = value is num ? value.toDouble() : double.tryParse('$value');
    return result != null && result.isFinite ? result : null;
  }

  @override
  void didUpdateWidget(covariant EntityControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entity.entityId != _entity.entityId) {
      sessionGeneration++;
      clearPendingInteraction();
    }
  }

  Future<void> _execute(
    String service, [
    Map<String, dynamic> data = const {},
  ]) async {
    if (_disabled || !_service(service)) return;
    final lease = captureHaSession();
    if (lease == null) return;
    final entity = _entity;
    final executor = ref.read(haActionExecutorProvider);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final payload = Map<String, dynamic>.of(data);
      if (entity.domain == 'lock' &&
          (service == 'unlock' || entity.attributes['code_format'] != null)) {
        final route = CupertinoDialogRoute<Map<String, dynamic>>(
          context: context,
          builder: (_) =>
              _LockConfirmation(entity: entity, unlock: service == 'unlock'),
        );
        _modal = route;
        final confirmed = await Navigator.of(context).push(route);
        if (identical(_modal, route)) _modal = null;
        if (confirmed == null || !_current(lease, entity.entityId)) return;
        payload.addAll(confirmed);
      }
      await _dispatch(lease, entity.entityId, executor, service, payload);
    } catch (error) {
      if (_current(lease, entity.entityId)) {
        setState(() => _error = actionErrorLabel(_l10n, error));
      }
    } finally {
      _finish(lease);
    }
  }

  Future<void> _dispatch(
    HaSessionLease lease,
    String entityId,
    HaActionExecutor executor,
    String service,
    Map<String, dynamic> payload,
  ) async {
    if (!_current(lease, entityId) ||
        !_service(service) ||
        !identical(ref.read(haActionExecutorProvider), executor) ||
        !_supportedPayload(service, payload)) {
      return;
    }
    setState(() => _sending = true);
    await executor.execute(
      domain: _entity.domain,
      service: service,
      entityId: entityId,
      serviceData: payload,
    );
  }

  void _finish(HaSessionLease lease) {
    if (mounted && sessionCurrent(lease.generation)) {
      setState(() {
        _busy = false;
        _sending = false;
        _drafts.clear();
      });
    }
  }

  bool _supportedPayload(String service, Map<String, dynamic> data) {
    if (_entity.state == 'unavailable' ||
        data.values.any((value) => value is num && !value.isFinite)) {
      return false;
    }
    bool flag(int mask) => _feature(mask);
    switch (_entity.domain) {
      case 'cover':
        final required = {
          'open_cover': 1,
          'close_cover': 2,
          'set_cover_position': 4,
          'stop_cover': 8,
        }[service];
        return required != null &&
            flag(required) &&
            (service != 'set_cover_position' ||
                (data['position'] is int &&
                    (data['position'] as int) >= 0 &&
                    (data['position'] as int) <= 100));
      case 'lock':
        return {'lock', 'unlock'}.contains(service) &&
            (_attributes['code_format'] == null ||
                _attributes['code_format'] == '' ||
                (data['code'] is String &&
                    (data['code'] as String).isNotEmpty &&
                    (data['code'] as String).length <= 128));
      case 'climate':
        final option = {
          'set_hvac_mode': ('hvac_mode', 'hvac_modes', 0),
          'set_fan_mode': ('fan_mode', 'fan_modes', 8),
          'set_preset_mode': ('preset_mode', 'preset_modes', 16),
        }[service];
        if (option != null) {
          return (option.$3 == 0 || flag(option.$3)) &&
              _options(option.$2).contains(data[option.$1]);
        }
        if (service != 'set_temperature') return false;
        final min = _number(_attributes['min_temp']),
            max = _number(_attributes['max_temp']);
        if (min == null || max == null) return false;
        bool range(Object? value) =>
            value is num && value >= min && value <= max;
        if (data.containsKey('temperature')) {
          return flag(1) && range(data['temperature']);
        }
        final low = data['target_temp_low'], high = data['target_temp_high'];
        return flag(2) &&
            range(low) &&
            range(high) &&
            (low as num) <= (high as num);
      case 'fan':
        return service == 'set_percentage'
            ? flag(1) &&
                  data['percentage'] is int &&
                  (data['percentage'] as int) >= 0 &&
                  (data['percentage'] as int) <= 100
            : service == 'set_preset_mode' &&
                  (flag(1) || flag(8)) &&
                  _options('preset_modes').contains(data['preset_mode']);
      case 'number':
      case 'input_number':
        final min = _number(_attributes['min']),
            max = _number(_attributes['max']),
            value = data['value'];
        return service == 'set_value' &&
            min != null &&
            max != null &&
            value is num &&
            value >= min &&
            value <= max;
      case 'select':
      case 'input_select':
        return service == 'select_option' &&
            _options('options').contains(data['option']);
      case 'media_player':
        final required = {
          'media_pause': 1,
          'media_play': 16384,
          'media_previous_track': 16,
          'media_next_track': 32,
          'media_stop': 4096,
          'volume_set': 4,
          'volume_mute': 8,
        }[service];
        if (required == null || !flag(required)) return false;
        if (service == 'volume_set') {
          final value = data['volume_level'];
          return value is num && value >= 0 && value <= 1;
        }
        return service != 'volume_mute' || data['is_volume_muted'] is bool;
      default:
        return false;
    }
  }

  Widget _button(
    String label,
    String service, {
    Map<String, dynamic> data = const {},
  }) => CupertinoButton(
    key: ValueKey('entity-control-$service'),
    onPressed: _disabled ? null : haCallback(() => _execute(service, data)),
    child: Text(label),
  );

  Widget _slider({
    required String label,
    required String field,
    required String service,
    required double value,
    required double min,
    required double max,
    double step = 1,
    String unit = '',
    Map<String, dynamic> extra = const {},
  }) {
    if (!min.isFinite ||
        !max.isFinite ||
        max <= min ||
        step <= 0 ||
        !step.isFinite) {
      return const SizedBox.shrink();
    }
    final lease = captureHaSession();
    final entityId = _entity.entityId;
    double snap(double raw) => double.parse(
      (min + ((raw - min) / step).round() * step)
          .clamp(min, max)
          .toStringAsFixed(6),
    );
    final current = (_drafts[field] ?? value).clamp(min, max);
    final divisions = ((max - min) / step).round();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('$label · ${snap(current)}$unit'),
          Semantics(
            label: label,
            child: CupertinoSlider(
              key: ValueKey('entity-control-$field'),
              value: current,
              min: min,
              max: max,
              divisions: divisions > 0 && divisions <= 1000 ? divisions : null,
              onChanged: _disabled || lease == null
                  ? null
                  : (value) {
                      if (value.isFinite && _current(lease, entityId)) {
                        setState(() => _drafts[field] = snap(value));
                      }
                    },
              onChangeEnd: _disabled || lease == null
                  ? null
                  : (value) {
                      if (!value.isFinite || !_current(lease, entityId)) return;
                      _execute(service, {
                        ...extra,
                        field: {'position', 'percentage'}.contains(field)
                            ? snap(value).round()
                            : snap(value),
                      });
                    },
            ),
          ),
        ],
      ),
    );
  }

  Widget _choice(
    String label,
    String service,
    String field,
    List<String> options,
    dynamic value,
  ) {
    return CupertinoListTile(
      title: Text(label),
      additionalInfo: Text(value?.toString() ?? '—'),
      trailing: const CupertinoListTileChevron(),
      onTap: _disabled
          ? null
          : haCallback(() async {
              if (_busy) return;
              final lease = captureHaSession();
              if (lease == null) return;
              final entityId = _entity.entityId,
                  executor = ref.read(haActionExecutorProvider);
              setState(() {
                _busy = true;
                _error = null;
              });
              try {
                final route = CupertinoModalPopupRoute<String>(
                  builder: (context) => CupertinoActionSheet(
                    title: Text(label),
                    actions: [
                      for (final option in options)
                        CupertinoActionSheetAction(
                          isDefaultAction: option == value,
                          onPressed: () => closeDashboardModal(context, option),
                          child: Text(option),
                        ),
                    ],
                    cancelButton: CupertinoActionSheetAction(
                      onPressed: () => closeDashboardModal(context),
                      child: Text(_l10n.commonCancel),
                    ),
                  ),
                );
                _modal = route;
                final selected = await Navigator.of(context).push(route);
                if (identical(_modal, route)) _modal = null;
                if (selected != null) {
                  await _dispatch(lease, entityId, executor, service, {
                    field: selected,
                  });
                }
              } catch (error) {
                if (_current(lease, entityId)) {
                  setState(() => _error = actionErrorLabel(_l10n, error));
                }
              } finally {
                _finish(lease);
              }
            }),
    );
  }

  @override
  Widget build(BuildContext context) {
    watchHaSession();
    ref.watch(
      publicHaEntitiesProvider.select(
        (value) => (
          value.isLoading,
          value.hasError,
          value.value?[widget.entity.entityId],
        ),
      ),
    );
    ref.listen(publicHaEntitiesProvider, (previous, next) {
      if (next.isLoading ||
          next.hasError ||
          next.value?[widget.entity.entityId] == null) {
        setState(() {
          sessionGeneration++;
          clearPendingInteraction();
        });
      }
    });
    if (!haSessionAvailable || _currentEntity == null) {
      return const SizedBox.shrink();
    }
    ref.watch(haActionExecutorProvider);
    if (!_domains.contains(_entity.domain)) return const SizedBox.shrink();
    final catalog = ref.watch(haActionsProvider);
    if (catalog.isLoading) {
      return const CupertinoActivityIndicator();
    }
    if (catalog.hasError) {
      return CupertinoButton(
        onPressed: haCallback(() => ref.invalidate(haActionsProvider)),
        child: Text('${_l10n.commonError} · ${_l10n.commonRetry}'),
      );
    }
    final controlsLease = captureHaSession();
    final controlsEntityId = _entity.entityId;
    final controls = <Widget>[];
    final buttons = <Widget>[];
    void button(String label, String service, {bool supported = true}) {
      if (supported && _service(service)) buttons.add(_button(label, service));
    }

    void choice(
      String label,
      String service,
      String field,
      String attribute, {
      bool supported = true,
      dynamic value,
    }) {
      final options = _options(attribute);
      if (supported && _service(service) && options.isNotEmpty) {
        controls.add(
          _choice(label, service, field, options, value ?? _attributes[field]),
        );
      }
    }

    void slider(
      String label,
      String service,
      String field,
      dynamic value,
      double min,
      double max, {
      double step = 1,
      bool supported = true,
      String unit = '',
      Map<String, dynamic> extra = const {},
    }) {
      final numeric = _number(value);
      if (supported && _service(service) && numeric != null) {
        controls.add(
          _slider(
            label: label,
            field: field,
            service: service,
            value: numeric,
            min: min,
            max: max,
            step: step,
            unit: unit,
            extra: extra,
          ),
        );
      }
    }

    switch (_entity.domain) {
      case 'climate':
        choice(
          _l10n.entityControlHvacMode,
          'set_hvac_mode',
          'hvac_mode',
          'hvac_modes',
          value: _entity.state,
        );
        choice(
          _l10n.entityControlFanMode,
          'set_fan_mode',
          'fan_mode',
          'fan_modes',
          supported: _feature(8),
        );
        choice(
          _l10n.entityControlPreset,
          'set_preset_mode',
          'preset_mode',
          'preset_modes',
          supported: _feature(16),
        );
        final min = _number(_attributes['min_temp']);
        final max = _number(_attributes['max_temp']);
        final step = _number(_attributes['target_temp_step']) ?? 0.5;
        final unit = _attributes['temperature_unit']?.toString() ?? '°';
        if (min != null && max != null) {
          slider(
            _l10n.entityControlTemperature,
            'set_temperature',
            'temperature',
            _attributes['temperature'],
            min,
            max,
            step: step,
            supported: _feature(1),
            unit: unit,
          );
          final low = _number(_attributes['target_temp_low']);
          final high = _number(_attributes['target_temp_high']);
          if (_feature(2) && low != null && high != null) {
            slider(
              _l10n.entityControlTargetLow,
              'set_temperature',
              'target_temp_low',
              low,
              min,
              high.clamp(min, max),
              step: step,
              unit: unit,
              extra: {'target_temp_high': high},
            );
            slider(
              _l10n.entityControlTargetHigh,
              'set_temperature',
              'target_temp_high',
              high,
              low.clamp(min, max),
              max,
              step: step,
              unit: unit,
              extra: {'target_temp_low': low},
            );
          }
        }
      case 'cover':
        button(_l10n.entityControlOpen, 'open_cover', supported: _feature(1));
        button(_l10n.commonClose, 'close_cover', supported: _feature(2));
        button(_l10n.entityControlStop, 'stop_cover', supported: _feature(8));
        slider(
          _l10n.entityControlPosition,
          'set_cover_position',
          'position',
          _attributes['current_position'],
          0,
          100,
          supported: _feature(4),
          unit: '%',
        );
      case 'lock':
        button(_l10n.entityControlLock, 'lock');
        button(_l10n.entityControlUnlock, 'unlock');
      case 'fan':
        slider(
          _l10n.entityControlSpeed,
          'set_percentage',
          'percentage',
          _attributes['percentage'],
          0,
          100,
          supported: _feature(1),
          step: _number(_attributes['percentage_step']) ?? 1,
          unit: '%',
        );
        choice(
          _l10n.entityControlPreset,
          'set_preset_mode',
          'preset_mode',
          'preset_modes',
          supported: _feature(1) || _feature(8),
        );
      case 'number' || 'input_number':
        final min = _number(_attributes['min']);
        final max = _number(_attributes['max']);
        if (min != null && max != null) {
          slider(
            _l10n.entityControlValue,
            'set_value',
            'value',
            _entity.state,
            min,
            max,
            step: _number(_attributes['step']) ?? 1,
            unit: _attributes['unit_of_measurement']?.toString() ?? '',
          );
        }
      case 'select' || 'input_select':
        choice(
          _l10n.entityControlOption,
          'select_option',
          'option',
          'options',
          value: _entity.state,
        );
      case 'media_player':
        button(
          _l10n.entityControlPrevious,
          'media_previous_track',
          supported: _feature(16),
        );
        if (_entity.state == 'playing') {
          button(
            _l10n.entityControlPause,
            'media_pause',
            supported: _feature(1),
          );
        } else {
          button(
            _l10n.mediaActionPlay,
            'media_play',
            supported: _feature(16384),
          );
        }
        button(_l10n.commonNext, 'media_next_track', supported: _feature(32));
        button(
          _l10n.entityControlStop,
          'media_stop',
          supported: _feature(4096),
        );
        slider(
          _l10n.entityControlVolume,
          'volume_set',
          'volume_level',
          _attributes['volume_level'],
          0,
          1,
          step: 0.01,
          supported: _feature(4),
        );
        if (_feature(8) &&
            _service('volume_mute') &&
            _attributes['is_volume_muted'] is bool) {
          controls.add(
            CupertinoListTile(
              title: Text(_l10n.entityControlMute),
              trailing: CupertinoSwitch(
                value: _attributes['is_volume_muted'] as bool,
                onChanged: _disabled || controlsLease == null
                    ? null
                    : (value) {
                        if (_current(controlsLease, controlsEntityId)) {
                          _execute('volume_mute', {'is_volume_muted': value});
                        }
                      },
              ),
            ),
          );
        }
    }
    if (buttons.isNotEmpty) {
      controls.insert(0, Wrap(spacing: 4, children: buttons));
    }
    if (_sending) {
      controls.add(const Center(child: CupertinoActivityIndicator()));
    }
    if (_error != null) {
      controls.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            _error!,
            style: TextStyle(
              color: CupertinoColors.systemRed.resolveFrom(context),
            ),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: controls,
    );
  }
}

class _LockConfirmation extends StatefulWidget {
  const _LockConfirmation({required this.entity, required this.unlock});
  final HaEntity entity;
  final bool unlock;
  @override
  State<_LockConfirmation> createState() => _LockConfirmationState();
}

class _LockConfirmationState extends State<_LockConfirmation> {
  final _code = TextEditingController();
  bool get _needsCode =>
      widget.entity.attributes['code_format'] is String &&
      (widget.entity.attributes['code_format'] as String).isNotEmpty;
  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return CupertinoAlertDialog(
      title: Text(
        widget.unlock
            ? l10n.entityControlConfirmUnlock
            : l10n.entityControlLock,
      ),
      content: Column(
        children: [
          Text(widget.entity.friendlyName),
          if (_needsCode)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: CupertinoTextField(
                controller: _code,
                placeholder: l10n.entityControlCode,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                onChanged: (_) {
                  if (mounted) setState(() {});
                },
              ),
            ),
        ],
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => closeDashboardModal(context),
          child: Text(l10n.commonCancel),
        ),
        CupertinoDialogAction(
          isDestructiveAction: widget.unlock,
          onPressed:
              _needsCode &&
                  (_code.text.trim().isEmpty || _code.text.length > 128)
              ? null
              : () => closeDashboardModal(context, <String, dynamic>{
                  if (_needsCode && _code.text.trim().isNotEmpty)
                    'code': _code.text.trim(),
                }),
          child: Text(
            widget.unlock ? l10n.entityControlUnlock : l10n.entityControlLock,
          ),
        ),
      ],
    );
  }
}
