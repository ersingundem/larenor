import 'package:flutter/cupertino.dart';

import '../../../shared/widgets/app_page_scaffold.dart';
import '../../home_resources/domain/home_resource_models.dart';
import '../../server/services/domain/server_service_models.dart';
import '../data/room_comfort_source_api.dart';
import '../domain/room_comfort_source_models.dart';

final class RoomComfortSetupStrings {
  const RoomComfortSetupStrings({
    required this.title,
    required this.action,
    required this.description,
    required this.service,
    required this.noService,
    required this.room,
    required this.area,
    required this.addRoom,
    required this.removeRoom,
    required this.weather,
    required this.aqi,
    required this.climate,
    required this.window,
    required this.temperature,
    required this.humidity,
    required this.co2,
    required this.voc,
    required this.smoke,
    required this.occupancy,
    required this.targetTemperature,
    required this.temperatureTolerance,
    required this.humidityHigh,
    required this.co2High,
    required this.vocHigh,
    required this.aqiLimit,
    required this.freezeThreshold,
    required this.indoorAge,
    required this.outdoorAge,
    required this.occupancyAge,
    required this.previewTtl,
    required this.save,
    required this.failed,
    required this.choose,
  });

  final String title, action, description, service, noService, room, area;
  final String addRoom, removeRoom, weather, aqi, climate, window;
  final String temperature, humidity, co2, voc, smoke, occupancy;
  final String targetTemperature, temperatureTolerance, humidityHigh;
  final String co2High, vocHigh, aqiLimit, freezeThreshold;
  final String indoorAge, outdoorAge, occupancyAge, previewTtl;
  final String save, failed, choose;

  static const en = RoomComfortSetupStrings(
    title: 'Room comfort sources',
    action: 'Configure verified sources',
    description: 'Choose current Home Assistant registry entities and enter an explicit comfort policy. Core verifies live domains, units, device capabilities, and revisions before saving.',
    service: 'Home Assistant service',
    noService: 'No authenticated Home Assistant service is available.',
    room: 'Room',
    area: 'Area resource',
    addRoom: 'Add room',
    removeRoom: 'Remove room',
    weather: 'Weather entity',
    aqi: 'Outdoor AQI entity',
    climate: 'Climate entity',
    window: 'Window cover entity',
    temperature: 'Temperature sensor',
    humidity: 'Humidity sensor',
    co2: 'CO₂ sensor',
    voc: 'VOC sensor',
    smoke: 'Smoke sensor',
    occupancy: 'Occupancy sensor',
    targetTemperature: 'Target temperature (milli °C)',
    temperatureTolerance: 'Temperature tolerance (milli °C)',
    humidityHigh: 'High humidity (permille)',
    co2High: 'High CO₂ (ppm)',
    vocHigh: 'High VOC (ppb)',
    aqiLimit: 'Outdoor AQI limit',
    freezeThreshold: 'Freeze threshold (milli °C)',
    indoorAge: 'Indoor reading max age (ms)',
    outdoorAge: 'Outdoor reading max age (ms)',
    occupancyAge: 'Occupancy max age (ms)',
    previewTtl: 'Confirmation preview lifetime (ms)',
    save: 'Verify and save',
    failed: 'The selected registry entities or policy could not be verified.',
    choose: 'Choose',
  );

  static const tr = RoomComfortSetupStrings(
    title: 'Oda konforu kaynakları',
    action: 'Doğrulanmış kaynakları yapılandır',
    description: 'Güncel Home Assistant kayıt varlıklarını seçin ve açık bir konfor politikası girin. Core kaydetmeden önce canlı alan adlarını, birimleri, cihaz yeteneklerini ve revizyonları doğrular.',
    service: 'Home Assistant servisi',
    noService: 'Kimliği doğrulanmış Home Assistant servisi yok.',
    room: 'Oda',
    area: 'Alan kaynağı',
    addRoom: 'Oda ekle',
    removeRoom: 'Odayı kaldır',
    weather: 'Hava durumu varlığı',
    aqi: 'Dış hava AQI varlığı',
    climate: 'İklimlendirme varlığı',
    window: 'Pencere örtüsü varlığı',
    temperature: 'Sıcaklık sensörü',
    humidity: 'Nem sensörü',
    co2: 'CO₂ sensörü',
    voc: 'VOC sensörü',
    smoke: 'Duman sensörü',
    occupancy: 'Varlık sensörü',
    targetTemperature: 'Hedef sıcaklık (mili °C)',
    temperatureTolerance: 'Sıcaklık toleransı (mili °C)',
    humidityHigh: 'Yüksek nem (binde)',
    co2High: 'Yüksek CO₂ (ppm)',
    vocHigh: 'Yüksek VOC (ppb)',
    aqiLimit: 'Dış hava AQI sınırı',
    freezeThreshold: 'Donma eşiği (mili °C)',
    indoorAge: 'İç ölçüm azami yaşı (ms)',
    outdoorAge: 'Dış ölçüm azami yaşı (ms)',
    occupancyAge: 'Varlık azami yaşı (ms)',
    previewTtl: 'Onay önizlemesi ömrü (ms)',
    save: 'Doğrula ve kaydet',
    failed: 'Seçilen kayıt varlıkları veya politika doğrulanamadı.',
    choose: 'Seç',
  );
}

class RoomComfortSourceScreen extends StatefulWidget {
  const RoomComfortSourceScreen({
    super.key,
    required this.api,
    required this.strings,
    required this.onFinished,
  });

  final AccountRoomComfortSourceApi api;
  final RoomComfortSetupStrings strings;
  final Future<void> Function() onFinished;

  @override
  State<RoomComfortSourceScreen> createState() =>
      _RoomComfortSourceScreenState();
}

class _RoomComfortSourceScreenState extends State<RoomComfortSourceScreen> {
  final _policy = <String, TextEditingController>{
    for (final key in _policyKeys) key: TextEditingController(),
  };
  RoomComfortSetupCatalog? _catalog;
  RoomComfortEntityCatalog? _entities;
  ServerService? _service;
  String? _weather, _aqi;
  final List<_RoomFields> _rooms = [];
  bool _loading = true, _saving = false, _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    widget.api.retire();
    for (final value in _policy.values) {
      value.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final catalog = await widget.api.load();
      if (!mounted) return;
      final configuration = catalog.configuration;
      final service = configuration == null
          ? null
          : catalog.services
                .where(
                  (item) =>
                      item.id == configuration.serviceId &&
                      item.revision == configuration.serviceRevision,
                )
                .firstOrNull;
      setState(() {
        _catalog = catalog;
        _service = service;
        _apply(configuration, catalog);
      });
      if (service != null) await _loadEntities(service, clear: false);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _apply(
    RoomComfortSourceConfiguration? value,
    RoomComfortSetupCatalog catalog,
  ) {
    _weather = value?.weatherEntityId;
    _aqi = value?.aqiEntityId;
    final values = value == null
        ? const <String, int>{}
        : <String, int>{
            'targetTemperatureMilliC': value.targetTemperatureMilliC,
            'temperatureToleranceMilliC': value.temperatureToleranceMilliC,
            'humidityHighPermille': value.humidityHighPermille,
            'co2HighPpm': value.co2HighPpm,
            'vocHighPpb': value.vocHighPpb,
            'outdoorAqiLimit': value.outdoorAqiLimit,
            'freezeThresholdMilliC': value.freezeThresholdMilliC,
            'indoorMaxAgeMs': value.indoorMaxAgeMs,
            'outdoorMaxAgeMs': value.outdoorMaxAgeMs,
            'occupancyMaxAgeMs': value.occupancyMaxAgeMs,
            'previewTtlMs': value.previewTtlMs,
          };
    for (final entry in _policy.entries) {
      entry.value.text = values[entry.key]?.toString() ?? '';
    }
    _rooms
      ..clear()
      ..addAll(
        value?.rooms.map((source) => _RoomFields.from(source, catalog)) ??
            [_RoomFields()],
      );
  }

  Future<void> _loadEntities(
    ServerService service, {
    required bool clear,
  }) async {
    setState(() {
      _loading = true;
      _failed = false;
      _entities = null;
      if (clear) {
        _weather = null;
        _aqi = null;
        for (final room in _rooms) {
          room.clearEntities();
        }
      }
    });
    try {
      final value = await widget.api.entities(service);
      if (!mounted || !identical(_service, service)) return;
      setState(() => _entities = value);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<T?> _pick<T>(String title, List<T> values, String Function(T) label) =>
      showCupertinoModalPopup<T>(
        context: context,
        builder: (context) => CupertinoActionSheet(
          title: Text(title),
          actions: [
            for (final value in values)
              CupertinoActionSheetAction(
                onPressed: () => Navigator.pop(context, value),
                child: Text(label(value)),
              ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context),
            child: Text(CupertinoLocalizations.of(context).cancelButtonLabel),
          ),
        ),
      );

  int _number(String key, int minimum, int maximum) {
    final value = int.tryParse(_policy[key]!.text.trim());
    if (value == null || value < minimum || value > maximum) {
      throw const FormatException();
    }
    return value;
  }

  Future<void> _save() async {
    final catalog = _catalog;
    final service = _service;
    final entities = _entities;
    if (catalog == null || service == null || entities == null) return;
    setState(() {
      _saving = true;
      _failed = false;
    });
    try {
      final rooms = _rooms.map((room) => room.source()).toList(growable: false);
      final usedRooms = rooms.map((room) => room.roomId).toSet();
      final usedEntities = <String>{
        _weather ?? '',
        _aqi ?? '',
        for (final room in rooms) ...[
          room.climateEntityId,
          room.windowEntityId,
          room.temperatureEntityId,
          room.humidityEntityId,
          room.co2EntityId,
          room.vocEntityId,
          room.smokeEntityId,
          room.occupancyEntityId,
        ],
      };
      if (_weather == null ||
          _aqi == null ||
          rooms.isEmpty ||
          usedRooms.length != rooms.length ||
          usedEntities.contains('') ||
          usedEntities.length != 2 + rooms.length * 8) {
        throw const FormatException();
      }
      await widget.api.save({
        'schemaVersion': 1,
        'expectedRevision': catalog.configuration?.revision,
        'serviceId': service.id,
        'expectedServiceRevision': service.revision,
        'weatherEntityId': _weather,
        'aqiEntityId': _aqi,
        'targetTemperatureMilliC': _number(
          'targetTemperatureMilliC',
          5000,
          35000,
        ),
        'temperatureToleranceMilliC': _number(
          'temperatureToleranceMilliC',
          100,
          10000,
        ),
        'humidityHighPermille': _number('humidityHighPermille', 1, 1000),
        'co2HighPpm': _number('co2HighPpm', 400, 10000),
        'vocHighPpb': _number('vocHighPpb', 1, 100000),
        'outdoorAqiLimit': _number('outdoorAqiLimit', 1, 500),
        'freezeThresholdMilliC': _number(
          'freezeThresholdMilliC',
          -50000,
          15000,
        ),
        'indoorMaxAgeMs': _number('indoorMaxAgeMs', 1000, 86400000),
        'outdoorMaxAgeMs': _number('outdoorMaxAgeMs', 1000, 86400000),
        'occupancyMaxAgeMs': _number('occupancyMaxAgeMs', 1000, 86400000),
        'previewTtlMs': _number('previewTtlMs', 1000, 60000),
        'rooms': [for (final room in rooms) room.toJson()],
      });
      if (mounted) await widget.onFinished();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.strings;
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(text.title),
        leading: CupertinoButton(
          key: const ValueKey('comfort-setup-close'),
          padding: EdgeInsets.zero,
          onPressed: _saving ? null : widget.onFinished,
          child: const Icon(CupertinoIcons.back),
        ),
      ),
      child: SafeArea(
        child: _loading && _catalog == null
            ? const Center(child: CupertinoActivityIndicator())
            : ListView(
                padding: const EdgeInsets.only(bottom: 48),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
                    child: Text(text.description),
                  ),
                  if (_failed)
                    Semantics(
                      liveRegion: true,
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(text.failed),
                      ),
                    ),
                  _sourceSection(text),
                  for (var index = 0; index < _rooms.length; index++)
                    _roomSection(text, _rooms[index], index),
                  _policySection(text),
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: CupertinoButton.filled(
                      key: const ValueKey('comfort-setup-save'),
                      onPressed: _saving || _loading ? null : _save,
                      child: _saving
                          ? const CupertinoActivityIndicator()
                          : Text(text.save),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _sourceSection(RoomComfortSetupStrings text) {
    final catalog = _catalog;
    final entities = _entities;
    return CupertinoFormSection.insetGrouped(
      header: Text(text.service),
      children: [
        if (catalog == null || catalog.services.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(text.noService),
          )
        else
          _PickerRow(
            key: const ValueKey('comfort-setup-service'),
            label: text.service,
            value: _service?.name,
            choose: text.choose,
            onPressed: () async {
              final value = await _pick(
                text.service,
                catalog.services,
                (item) => item.name,
              );
              if (value != null && mounted && !identical(value, _service)) {
                setState(() => _service = value);
                await _loadEntities(value, clear: true);
              }
            },
          ),
        _PickerRow(
          label: text.weather,
          value: _weather,
          choose: text.choose,
          onPressed: entities == null
              ? null
              : () async {
                  final value = await _pick(
                    text.weather,
                    entities.weather,
                    (v) => v,
                  );
                  if (value != null && mounted) {
                    setState(() => _weather = value);
                  }
                },
        ),
        _PickerRow(
          label: text.aqi,
          value: _aqi,
          choose: text.choose,
          onPressed: entities == null
              ? null
              : () async {
                  final value = await _pick(
                    text.aqi,
                    entities.sensors,
                    (v) => v,
                  );
                  if (value != null && mounted) setState(() => _aqi = value);
                },
        ),
      ],
    );
  }

  Widget _roomSection(
    RoomComfortSetupStrings text,
    _RoomFields room,
    int index,
  ) {
    final catalog = _catalog;
    final entities = _entities;
    final fields = <(String, String?, List<String>, void Function(String))>[
      (
        text.climate,
        room.climate,
        entities?.climates ?? const [],
        (v) => room.climate = v,
      ),
      (
        text.window,
        room.window,
        entities?.covers ?? const [],
        (v) => room.window = v,
      ),
      (
        text.temperature,
        room.temperature,
        entities?.sensors ?? const [],
        (v) => room.temperature = v,
      ),
      (
        text.humidity,
        room.humidity,
        entities?.sensors ?? const [],
        (v) => room.humidity = v,
      ),
      (text.co2, room.co2, entities?.sensors ?? const [], (v) => room.co2 = v),
      (text.voc, room.voc, entities?.sensors ?? const [], (v) => room.voc = v),
      (
        text.smoke,
        room.smoke,
        entities?.binarySensors ?? const [],
        (v) => room.smoke = v,
      ),
      (
        text.occupancy,
        room.occupancy,
        entities?.binarySensors ?? const [],
        (v) => room.occupancy = v,
      ),
    ];
    return CupertinoFormSection.insetGrouped(
      header: Text('${text.room} ${index + 1}'),
      children: [
        _PickerRow(
          label: text.room,
          value: room.room?.label,
          choose: text.choose,
          onPressed: catalog == null
              ? null
              : () async {
                  final value = await _pick(
                    text.room,
                    catalog.rooms,
                    (v) => v.label,
                  );
                  if (value != null && mounted) {
                    setState(() => room.room = value);
                  }
                },
        ),
        _PickerRow(
          label: text.area,
          value: room.area?.label,
          choose: text.choose,
          onPressed: catalog == null
              ? null
              : () async {
                  final value = await _pick(
                    text.area,
                    catalog.areas,
                    (v) => v.label,
                  );
                  if (value != null && mounted) {
                    setState(() => room.area = value);
                  }
                },
        ),
        for (final field in fields)
          _PickerRow(
            label: field.$1,
            value: field.$2,
            choose: text.choose,
            onPressed: entities == null
                ? null
                : () async {
                    final value = await _pick(field.$1, field.$3, (v) => v);
                    if (value != null && mounted) {
                      setState(() => field.$4(value));
                    }
                  },
          ),
        CupertinoButton(
          onPressed: _saving
              ? null
              : () => setState(() {
                  if (_rooms.length == 1) {
                    _rooms.add(_RoomFields());
                  } else {
                    _rooms.remove(room);
                  }
                }),
          child: Text(_rooms.length == 1 ? text.addRoom : text.removeRoom),
        ),
        if (index == _rooms.length - 1 &&
            _rooms.length > 1 &&
            _rooms.length < 32)
          CupertinoButton(
            onPressed: _saving
                ? null
                : () => setState(() => _rooms.add(_RoomFields())),
            child: Text(text.addRoom),
          ),
      ],
    );
  }

  Widget _policySection(RoomComfortSetupStrings text) {
    final labels = <String, String>{
      'targetTemperatureMilliC': text.targetTemperature,
      'temperatureToleranceMilliC': text.temperatureTolerance,
      'humidityHighPermille': text.humidityHigh,
      'co2HighPpm': text.co2High,
      'vocHighPpb': text.vocHigh,
      'outdoorAqiLimit': text.aqiLimit,
      'freezeThresholdMilliC': text.freezeThreshold,
      'indoorMaxAgeMs': text.indoorAge,
      'outdoorMaxAgeMs': text.outdoorAge,
      'occupancyMaxAgeMs': text.occupancyAge,
      'previewTtlMs': text.previewTtl,
    };
    return CupertinoFormSection.insetGrouped(
      children: [
        for (final key in _policyKeys)
          CupertinoTextFormFieldRow(
            key: ValueKey('comfort-policy-$key'),
            controller: _policy[key],
            prefix: SizedBox(width: 190, child: Text(labels[key]!)),
            keyboardType: const TextInputType.numberWithOptions(signed: true),
            textAlign: TextAlign.end,
            placeholder: text.choose,
          ),
      ],
    );
  }
}

const _policyKeys = [
  'targetTemperatureMilliC',
  'temperatureToleranceMilliC',
  'humidityHighPermille',
  'co2HighPpm',
  'vocHighPpb',
  'outdoorAqiLimit',
  'freezeThresholdMilliC',
  'indoorMaxAgeMs',
  'outdoorMaxAgeMs',
  'occupancyMaxAgeMs',
  'previewTtlMs',
];

class _PickerRow extends StatelessWidget {
  const _PickerRow({
    super.key,
    required this.label,
    required this.value,
    required this.choose,
    required this.onPressed,
  });
  final String label, choose;
  final String? value;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => CupertinoFormRow(
    prefix: SizedBox(width: 140, child: Text(label)),
    child: CupertinoButton(
      padding: const EdgeInsets.symmetric(vertical: 10),
      minimumSize: const Size(48, 48),
      onPressed: onPressed,
      child: Text(value ?? choose, textAlign: TextAlign.end),
    ),
  );
}

class _RoomFields {
  _RoomFields();

  factory _RoomFields.from(
    RoomComfortRoomSource source,
    RoomComfortSetupCatalog catalog,
  ) {
    final value = _RoomFields();
    value
      ..room = catalog.rooms
          .where(
            (item) =>
                item.id == source.roomId &&
                item.revision == source.roomRevision,
          )
          .firstOrNull
      ..area = catalog.areas
          .where(
            (item) =>
                item.id == source.areaId &&
                item.revision == source.areaRevision,
          )
          .firstOrNull
      ..climate = source.climateEntityId
      ..window = source.windowEntityId
      ..temperature = source.temperatureEntityId
      ..humidity = source.humidityEntityId
      ..co2 = source.co2EntityId
      ..voc = source.vocEntityId
      ..smoke = source.smokeEntityId
      ..occupancy = source.occupancyEntityId;
    return value;
  }

  HomeResourceRecord? room, area;
  String? climate, window, temperature, humidity, co2, voc, smoke, occupancy;

  void clearEntities() {
    climate = window = temperature = humidity = co2 = voc = smoke = occupancy =
        null;
  }

  RoomComfortRoomSource source() {
    final roomValue = room, areaValue = area;
    if (roomValue == null ||
        areaValue == null ||
        climate == null ||
        window == null ||
        temperature == null ||
        humidity == null ||
        co2 == null ||
        voc == null ||
        smoke == null ||
        occupancy == null) {
      throw const FormatException();
    }
    return RoomComfortRoomSource(
      roomId: roomValue.id,
      roomRevision: roomValue.revision,
      areaId: areaValue.id,
      areaRevision: areaValue.revision,
      climateEntityId: climate!,
      windowEntityId: window!,
      temperatureEntityId: temperature!,
      humidityEntityId: humidity!,
      co2EntityId: co2!,
      vocEntityId: voc!,
      smokeEntityId: smoke!,
      occupancyEntityId: occupancy!,
    );
  }
}
