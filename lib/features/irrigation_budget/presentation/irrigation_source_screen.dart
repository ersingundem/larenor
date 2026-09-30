import 'package:flutter/cupertino.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../data/irrigation_source_api.dart';
import '../domain/irrigation_source_models.dart';

class IrrigationSourceScreen extends StatefulWidget {
  const IrrigationSourceScreen({super.key, required this.api});
  final CoreIrrigationSourceApi api;

  @override
  State<IrrigationSourceScreen> createState() => _IrrigationSourceScreenState();
}

class _IrrigationSourceScreenState extends State<IrrigationSourceScreen> {
  final _weather = TextEditingController();
  final _leak = TextEditingController();
  final _water = TextEditingController();
  final _endpoint = TextEditingController();
  final _password = TextEditingController();
  IrrigationSetupCatalog? _catalog;
  IrrigationServiceOption? _service;
  final List<_ZoneFields> _zones = [];
  bool _loading = true, _saving = false, _failed = false, _saved = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    widget.api.retire();
    _weather.dispose();
    _leak.dispose();
    _water.dispose();
    _endpoint.dispose();
    _password.dispose();
    for (final zone in _zones) {
      zone.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final value = await widget.api.load();
      if (!mounted) return;
      _apply(value);
      setState(() {
        _catalog = value;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  void _apply(IrrigationSetupCatalog value) {
    final source = value.source;
    _service = value.services
        .where((item) => item.id == source?.serviceId)
        .firstOrNull;
    _weather.text = source?.weatherEntityId ?? '';
    _leak.text = source?.leakEntityId ?? '';
    _water.text = source?.dailyWaterEntityId ?? '';
    for (final zone in _zones) {
      zone.dispose();
    }
    _zones
      ..clear()
      ..addAll(
        source?.zones.map((zone) => _ZoneFields.from(zone, value)) ??
            [_ZoneFields.empty(null)],
      );
    _endpoint.clear();
    _password.clear();
  }

  Future<void> _pickService() async {
    final catalog = _catalog;
    if (catalog == null || catalog.services.isEmpty) return;
    final value = await showCupertinoModalPopup<IrrigationServiceOption>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        actions: [
          for (final item in catalog.services)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(context, item),
              child: Text(item.name),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: Text(CupertinoLocalizations.of(context).cancelButtonLabel),
        ),
      ),
    );
    if (value != null && mounted) setState(() => _service = value);
  }

  Future<void> _pickRoom(_ZoneFields zone) async {
    final rooms = _catalog?.rooms ?? const <IrrigationRoomOption>[];
    if (rooms.isEmpty) return;
    final value = await showCupertinoModalPopup<IrrigationRoomOption>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        actions: [
          for (final item in rooms)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(context, item),
              child: Text(item.label),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: Text(CupertinoLocalizations.of(context).cancelButtonLabel),
        ),
      ),
    );
    if (value != null && mounted) setState(() => zone.room = value);
  }

  void _addZone() {
    if (_saving || _zones.length >= 32) return;
    setState(() => _zones.add(_ZoneFields.empty(null)));
  }

  void _removeZone(_ZoneFields zone) {
    if (_saving || _zones.length <= 1 || !_zones.remove(zone)) return;
    zone.dispose();
    setState(() {});
  }

  int _number(TextEditingController value, int minimum, int maximum) {
    final parsed = int.tryParse(value.text.trim());
    if (parsed == null || parsed < minimum || parsed > maximum) {
      throw const FormatException();
    }
    return parsed;
  }

  Future<void> _saveSource() async {
    final catalog = _catalog, service = _service;
    if (catalog == null || service == null || _zones.isEmpty) return;
    setState(() {
      _saving = true;
      _failed = false;
      _saved = false;
    });
    try {
      final source = catalog.source;
      await widget.api.saveSource({
        'schemaVersion': 1,
        'expectedRevision': source?.revision,
        'serviceId': service.id,
        'expectedServiceRevision': service.revision,
        'weatherEntityId': _weather.text.trim(),
        'leakEntityId': _leak.text.trim(),
        'dailyWaterEntityId': _water.text.trim(),
        'targetMoisturePermille': source?.targetMoisturePermille ?? 600,
        'soilMaxAgeMs': source?.soilMaxAgeMs ?? 60000,
        'safetyMaxAgeMs': source?.safetyMaxAgeMs ?? 60000,
        'forecastMaxAgeMs': source?.forecastMaxAgeMs ?? 21600000,
        'rainDeferralMilliMm': source?.rainDeferralMilliMm ?? 4000,
        'freezeThresholdMilliC': source?.freezeThresholdMilliC ?? 2000,
        'windLimitMilliMps': source?.windLimitMilliMps ?? 12000,
        'previewTtlMs': source?.previewTtlMs ?? 30000,
        'dailyLimitMl': source?.dailyLimitMl ?? 100000,
        'priceMicrosPerLiter': source?.priceMicrosPerLiter ?? 0,
        'zones': [for (final zone in _zones) zone.sourceBody(_number)],
      });
      final refreshed = await widget.api.load();
      if (!mounted) return;
      _apply(refreshed);
      setState(() {
        _catalog = refreshed;
        _saved = true;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveController() async {
    final catalog = _catalog, source = _catalog?.source;
    if (catalog == null || source == null) return;
    setState(() {
      _saving = true;
      _failed = false;
      _saved = false;
    });
    try {
      if (_endpoint.text.trim().isEmpty || _password.text.trim().isEmpty) {
        throw const FormatException();
      }
      await widget.api.saveController({
        'schemaVersion': 1,
        'expectedRevision': catalog.controller?.revision,
        'expectedSourceRevision': source.revision,
        'baseUrl': _endpoint.text.trim(),
        'passwordMd5': _password.text.trim(),
        'stations': [
          for (final zone in _zones)
            {
              'zoneId': zone.zoneId,
              'expectedZoneRevision': zone.zoneRevision,
              'stationIndex': _number(zone.station, 0, 255),
            },
        ],
      });
      final refreshed = await widget.api.load();
      if (!mounted) return;
      _apply(refreshed);
      setState(() {
        _catalog = refreshed;
        _saved = true;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ServiceRootScaffold(
      title: l10n.irrigationSetupTitle,
      slivers: [
        if (_loading)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CupertinoActivityIndicator()),
          )
        else
          SliverList(
            delegate: SliverChildListDelegate([
              if (_failed || _saved)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _failed
                        ? l10n.irrigationSetupFailed
                        : l10n.irrigationSetupSaved,
                    style: TextStyle(
                      color: _failed
                          ? CupertinoColors.systemRed
                          : CupertinoColors.activeGreen,
                    ),
                  ),
                ),
              SettingsSection(
                header: Text(l10n.irrigationSetupHomeAssistant),
                children: [
                  SettingsActionTile(
                    leading: const Icon(CupertinoIcons.link),
                    title: Text(l10n.irrigationSetupService),
                    additionalInfo: Text(_service?.name ?? '—'),
                    onTap: _saving ? null : _pickService,
                  ),
                  _field(
                    l10n.irrigationSetupWeatherEntity,
                    _weather,
                    fieldKey: const ValueKey('irrigation-weather-entity'),
                  ),
                  _field(l10n.irrigationSetupLeakEntity, _leak),
                  _field(l10n.irrigationSetupWaterEntity, _water),
                ],
              ),
              for (var index = 0; index < _zones.length; index++)
                _zoneSection(l10n, _zones[index], index),
              SettingsSection(
                children: [
                  SettingsActionTile(
                    buttonKey: const ValueKey('irrigation-source-add-zone'),
                    leading: const Icon(CupertinoIcons.add_circled),
                    title: Text(l10n.irrigationSetupAddZone),
                    onTap: _saving || _zones.length >= 32 ? null : _addZone,
                  ),
                ],
              ),
              SettingsSection(
                children: [
                  SettingsActionTile(
                    buttonKey: const ValueKey('irrigation-source-save'),
                    leading: const Icon(CupertinoIcons.check_mark),
                    title: Text(l10n.irrigationSetupSaveSource),
                    onTap: _saving || _service == null ? null : _saveSource,
                  ),
                ],
              ),
              SettingsSection(
                header: Text(l10n.irrigationSetupOpenSprinkler),
                children: [
                  _field(
                    l10n.irrigationSetupEndpoint,
                    _endpoint,
                    fieldKey: const ValueKey('irrigation-controller-endpoint'),
                  ),
                  _field(
                    l10n.irrigationSetupPasswordMd5,
                    _password,
                    obscure: true,
                    fieldKey: const ValueKey('irrigation-controller-password'),
                  ),
                  for (final zone in _zones)
                    _field(
                      '${zone.plant.text} · ${l10n.irrigationSetupStationIndex}',
                      zone.station,
                      number: true,
                    ),
                  SettingsActionTile(
                    buttonKey: const ValueKey('irrigation-controller-save'),
                    leading: const Icon(CupertinoIcons.drop),
                    title: Text(l10n.irrigationSetupSaveController),
                    onTap: _saving || _catalog?.source == null
                        ? null
                        : _saveController,
                  ),
                ],
              ),
              const SizedBox(height: 32),
            ]),
          ),
      ],
    );
  }

  Widget _zoneSection(AppLocalizations l10n, _ZoneFields zone, int index) =>
      SettingsSection(
        header: Text('${l10n.irrigationSetupRoom} ${index + 1}'),
        children: [
          SettingsActionTile(
            leading: const Icon(CupertinoIcons.house),
            title: Text(l10n.irrigationSetupRoom),
            additionalInfo: Text(zone.room?.label ?? '—'),
            onTap: _saving ? null : () => _pickRoom(zone),
          ),
          _field(l10n.irrigationSetupValveEntity, zone.valve),
          _field(l10n.irrigationSetupSoilEntity, zone.soil),
          _field(l10n.irrigationSetupPlantName, zone.plant),
          _field(l10n.irrigationSetupFlowEstimate, zone.flow, number: true),
          _field(l10n.irrigationSetupMaxDuration, zone.duration, number: true),
          if (_zones.length > 1)
            SettingsActionTile(
              leading: const Icon(
                CupertinoIcons.minus_circle,
                color: CupertinoColors.systemRed,
              ),
              title: Text(l10n.irrigationSetupRemoveZone),
              onTap: _saving ? null : () => _removeZone(zone),
            ),
        ],
      );

  Widget _field(
    String label,
    TextEditingController controller, {
    bool number = false,
    bool obscure = false,
    Key? fieldKey,
  }) => CupertinoTextFormFieldRow(
    key: fieldKey,
    controller: controller,
    prefix: SizedBox(width: 138, child: Text(label)),
    textAlign: TextAlign.end,
    keyboardType: number ? TextInputType.number : TextInputType.text,
    obscureText: obscure,
    autocorrect: false,
    enableSuggestions: false,
    enabled: !_saving,
  );
}

final class _ZoneFields {
  _ZoneFields({
    required this.room,
    required String valve,
    required String soil,
    required String plant,
    required String flow,
    required String duration,
    required String stationIndex,
    required this.zoneId,
    required this.zoneRevision,
  }) : valve = TextEditingController(text: valve),
       soil = TextEditingController(text: soil),
       plant = TextEditingController(text: plant),
       flow = TextEditingController(text: flow),
       duration = TextEditingController(text: duration),
       station = TextEditingController(text: stationIndex);

  factory _ZoneFields.from(
    IrrigationZoneSourceSettings value,
    IrrigationSetupCatalog catalog,
  ) => _ZoneFields(
    room: catalog.rooms.where((item) => item.id == value.roomId).firstOrNull,
    valve: value.valveEntityId,
    soil: value.soilMoistureEntityId,
    plant: value.plantName,
    flow: '${value.flowMlPerMinute}',
    duration: '${value.maxDurationSeconds}',
    stationIndex:
        catalog.controller?.stationIndexes[value.zoneId]?.toString() ?? '',
    zoneId: value.zoneId,
    zoneRevision: value.zoneRevision,
  );

  factory _ZoneFields.empty(IrrigationRoomOption? room) => _ZoneFields(
    room: room,
    valve: '',
    soil: '',
    plant: '',
    flow: '',
    duration: '',
    stationIndex: '',
    zoneId: '',
    zoneRevision: 0,
  );

  IrrigationRoomOption? room;
  final TextEditingController valve, soil, plant, flow, duration, station;
  final String zoneId;
  final int zoneRevision;

  Map<String, dynamic> sourceBody(
    int Function(TextEditingController, int, int) number,
  ) {
    final selectedRoom = room;
    if (selectedRoom == null || plant.text.trim().isEmpty) {
      throw const FormatException();
    }
    return {
      'roomId': selectedRoom.id,
      'roomRevision': selectedRoom.revision,
      'valveEntityId': valve.text.trim(),
      'soilMoistureEntityId': soil.text.trim(),
      'plantName': plant.text.trim(),
      'flowMlPerMinute': number(flow, 1, 1000000),
      'maxDurationSeconds': number(duration, 1, 7200),
    };
  }

  void dispose() {
    valve.dispose();
    soil.dispose();
    plant.dispose();
    flow.dispose();
    duration.dispose();
    station.dispose();
  }
}
