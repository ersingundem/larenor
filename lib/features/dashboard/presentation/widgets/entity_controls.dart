import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../ha_client/data/ha_api_exception.dart';
import '../../../ha_client/data/models/ha_entity.dart';
import '../../../ha_client/providers/ha_client_providers.dart';
import '../../../ha_tools/presentation/ha_actions_screen.dart';

/// Native controls for a current entity snapshot. Callers should keep light
/// and simple on/off controls alongside this widget. Services must exist in
/// the live catalog, and feature flags/attributes constrain entity support.
/// Flag definitions: home-assistant/core components/{domain}/const.py.
class EntityControls extends ConsumerStatefulWidget {
  const EntityControls({super.key, required this.entity});
  final HaEntity entity;

  @override
  ConsumerState<EntityControls> createState() => _EntityControlsState();
}

class _EntityControlsState extends ConsumerState<EntityControls> {
  bool _busy = false;
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

  HaEntity get _entity => widget.entity;
  Map<String, dynamic> get _attributes => _entity.attributes;
  AppLocalizations get _l10n => AppLocalizations.of(context);
  bool get _disabled => _busy || _entity.state == 'unavailable';
  bool _feature(int flag) =>
      (_number(_attributes['supported_features'])?.toInt() ?? 0) & flag != 0;
  bool _service(String service) =>
      ref
          .read(haActionsProvider)
          .value
          ?.any(
            (action) =>
                action.domain == _entity.domain && action.service == service,
          ) ??
      false;
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
      _drafts.clear();
      _error = null;
    }
  }

  Future<void> _execute(
    String service, [
    Map<String, dynamic> data = const {},
  ]) async {
    if (_disabled || !_service(service)) return;
    final entity = _entity;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final client = ref.read(haRestClientProvider);
      if (client == null) throw HaApiException(_l10n.haDisconnected);
      final payload = Map<String, dynamic>.of(data);
      if (entity.domain == 'lock' &&
          (service == 'unlock' || entity.attributes['code_format'] != null)) {
        final confirmed = await showCupertinoDialog<Map<String, dynamic>>(
          context: context,
          builder: (_) =>
              _LockConfirmation(entity: entity, unlock: service == 'unlock'),
        );
        if (confirmed == null || !mounted) return;
        payload.addAll(confirmed);
      }
      await client.callService(
        entity.domain,
        service,
        entityId: entity.entityId,
        serviceData: payload,
      );
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _drafts.clear();
        });
      }
    }
  }

  Widget _button(
    String label,
    String service, {
    Map<String, dynamic> data = const {},
  }) => CupertinoButton(
    key: ValueKey('entity-control-$service'),
    onPressed: _disabled ? null : () => _execute(service, data),
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
              onChanged: _disabled
                  ? null
                  : (value) => setState(() => _drafts[field] = snap(value)),
              onChangeEnd: _disabled
                  ? null
                  : (value) => _execute(service, {
                      ...extra,
                      field: {'position', 'percentage'}.contains(field)
                          ? snap(value).round()
                          : snap(value),
                    }),
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
          : () async {
              final selected = await showCupertinoModalPopup<String>(
                context: context,
                builder: (context) => CupertinoActionSheet(
                  title: Text(label),
                  actions: [
                    for (final option in options)
                      CupertinoActionSheetAction(
                        isDefaultAction: option == value,
                        onPressed: () => Navigator.pop(context, option),
                        child: Text(option),
                      ),
                  ],
                  cancelButton: CupertinoActionSheetAction(
                    onPressed: () => Navigator.pop(context),
                    child: Text(_l10n.commonCancel),
                  ),
                ),
              );
              if (selected != null && mounted) {
                await _execute(service, {field: selected});
              }
            },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_domains.contains(_entity.domain)) return const SizedBox.shrink();
    final catalog = ref.watch(haActionsProvider);
    if (catalog.isLoading && !catalog.hasValue) {
      return const CupertinoActivityIndicator();
    }
    if (catalog.hasError && !catalog.hasValue) {
      return CupertinoButton(
        onPressed: () => ref.invalidate(haActionsProvider),
        child: Text('${_l10n.commonError} · ${_l10n.commonRetry}'),
      );
    }
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
                onChanged: _disabled
                    ? null
                    : (value) =>
                          _execute('volume_mute', {'is_volume_muted': value}),
              ),
            ),
          );
        }
    }
    if (buttons.isNotEmpty) {
      controls.insert(0, Wrap(spacing: 4, children: buttons));
    }
    if (_busy) controls.add(const Center(child: CupertinoActivityIndicator()));
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
                onChanged: (_) => setState(() {}),
              ),
            ),
        ],
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        CupertinoDialogAction(
          isDestructiveAction: widget.unlock,
          onPressed: () => Navigator.pop(context, <String, dynamic>{
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
