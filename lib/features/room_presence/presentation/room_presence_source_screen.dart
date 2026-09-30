import 'package:flutter/cupertino.dart';

import '../../../shared/widgets/app_page_scaffold.dart';
import '../../home_resources/domain/home_resource_models.dart';
import '../../server/services/domain/server_service_models.dart';
import '../data/room_presence_source_api.dart';
import '../domain/room_presence_source_models.dart';

final class RoomPresenceSetupStrings {
  const RoomPresenceSetupStrings({
    required this.title,
    required this.action,
    required this.description,
    required this.service,
    required this.source,
    required this.room,
    required this.maxAge,
    required this.consent,
    required this.consentHint,
    required this.save,
    required this.revoke,
    required this.revokePrompt,
    required this.revoked,
    required this.choose,
    required this.failed,
    required this.noService,
  });
  final String title, action, description, service, source, room, maxAge;
  final String consent, consentHint, save, revoke, revokePrompt, revoked;
  final String choose, failed, noService;

  static const en = RoomPresenceSetupStrings(
    title: 'Room presence source',
    action: 'Configure room source',
    description: 'Choose a verified Home Assistant MQTT room-presence sensor while the tracked device is in the selected room. Core reads its live room state and distance before binding it. Presence remains advisory and never grants access.',
    service: 'Home Assistant service',
    source: 'MQTT room sensor',
    room: 'Current room',
    maxAge: 'Maximum signal age (ms)',
    consent: 'I consent to room presence processing',
    consentHint: 'Only reduced room evidence is retained. Raw provider identifiers and distance history are not returned to the app.',
    save: 'Verify live state and save',
    revoke: 'Revoke consent',
    revokePrompt: 'Stop room-presence reads and erase retained evidence?',
    revoked:
        'Consent is revoked. Select the source again to re-enable discovery.',
    choose: 'Choose',
    failed: 'The live MQTT room source could not be verified.',
    noService: 'No authenticated Home Assistant service is available.',
  );

  static const tr = RoomPresenceSetupStrings(
    title: 'Oda varlığı kaynağı',
    action: 'Oda kaynağını yapılandır',
    description: 'İzlenen cihaz seçilen odadayken doğrulanmış bir Home Assistant MQTT oda varlığı sensörü seçin. Core bağlamadan önce canlı oda durumunu ve mesafeyi okur. Varlık yalnız öneridir ve erişim vermez.',
    service: 'Home Assistant servisi',
    source: 'MQTT oda sensörü',
    room: 'Mevcut oda',
    maxAge: 'Azami sinyal yaşı (ms)',
    consent: 'Oda varlığı işlemeye izin veriyorum',
    consentHint: 'Yalnız azaltılmış oda kanıtı saklanır. Ham sağlayıcı kimlikleri ve mesafe geçmişi uygulamaya verilmez.',
    save: 'Canlı durumu doğrula ve kaydet',
    revoke: 'İzni geri çek',
    revokePrompt:
        'Oda varlığı okumaları durdurulsun ve saklanan kanıt silinsin mi?',
    revoked:
        'İzin geri çekildi. Keşfi yeniden açmak için kaynağı tekrar seçin.',
    choose: 'Seç',
    failed: 'Canlı MQTT oda kaynağı doğrulanamadı.',
    noService: 'Kimliği doğrulanmış Home Assistant servisi yok.',
  );
}

class RoomPresenceSourceScreen extends StatefulWidget {
  const RoomPresenceSourceScreen({
    super.key,
    required this.api,
    required this.strings,
    required this.onFinished,
  });
  final RoomPresenceSourceApi api;
  final RoomPresenceSetupStrings strings;
  final Future<void> Function() onFinished;

  @override
  State<RoomPresenceSourceScreen> createState() =>
      _RoomPresenceSourceScreenState();
}

class _RoomPresenceSourceScreenState extends State<RoomPresenceSourceScreen> {
  final _maxAge = TextEditingController();
  RoomPresenceSetupCatalog? _catalog;
  List<RoomPresenceEntityCandidate> _entities = const [];
  ServerService? _service;
  RoomPresenceEntityCandidate? _entity;
  HomeResourceRecord? _room;
  bool _consent = false, _loading = true, _saving = false, _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    widget.api.retire();
    _maxAge.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final catalog = await widget.api.load();
      if (!mounted) return;
      final existing = catalog.configuration;
      final service = existing == null
          ? null
          : catalog.services
                .where(
                  (value) =>
                      value.id == existing.serviceId &&
                      value.revision == existing.serviceRevision,
                )
                .firstOrNull;
      setState(() {
        _catalog = catalog;
        _service = service;
        _maxAge.text = existing?.maxSignalAgeMs.toString() ?? '';
        _consent = existing?.consentActive ?? false;
        final selected = existing?.rooms.firstOrNull;
        _room = selected == null
            ? null
            : catalog.rooms
                  .where(
                    (value) =>
                        value.id == selected.roomId &&
                        value.revision == selected.roomRevision,
                  )
                  .firstOrNull;
      });
      if (service != null) await _loadEntities(service, existing?.entityId);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadEntities(ServerService service, String? selected) async {
    setState(() {
      _loading = true;
      _entities = const [];
      _entity = null;
    });
    try {
      final values = await widget.api.entities(service);
      if (!mounted || !identical(_service, service)) return;
      setState(() {
        _entities = values;
        _entity = selected == null
            ? null
            : values.where((item) => item.entityId == selected).firstOrNull;
      });
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

  Future<void> _save() async {
    final catalog = _catalog;
    final service = _service;
    final entity = _entity;
    final room = _room;
    final maxAge = int.tryParse(_maxAge.text.trim());
    if (catalog == null ||
        service == null ||
        entity == null ||
        room == null ||
        !_consent ||
        maxAge == null ||
        maxAge < 1000 ||
        maxAge > 900000) {
      setState(() => _failed = true);
      return;
    }
    setState(() {
      _saving = true;
      _failed = false;
    });
    try {
      await widget.api.save({
        'schemaVersion': 1,
        'expectedRevision': catalog.configuration?.revision,
        'serviceId': service.id,
        'expectedServiceRevision': service.revision,
        'entityId': entity.entityId,
        'candidateId': entity.candidateId,
        'roomId': room.id,
        'expectedRoomRevision': room.revision,
        'maxSignalAgeMs': maxAge,
        'consent': true,
      });
      if (mounted) await widget.onFinished();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _revoke() async {
    final current = _catalog?.configuration;
    if (current == null || !current.consentActive || _saving) return;
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(widget.strings.revoke),
        content: Text(widget.strings.revokePrompt),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, false),
            child: Text(CupertinoLocalizations.of(context).cancelButtonLabel),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(context, true),
            child: Text(widget.strings.revoke),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _saving = true;
      _failed = false;
    });
    try {
      final revoked = await widget.api.revoke(current.revision);
      if (!mounted) return;
      final catalog = _catalog!;
      setState(() {
        _catalog = RoomPresenceSetupCatalog(
          services: catalog.services,
          rooms: catalog.rooms,
          configuration: revoked,
        );
        _consent = false;
        _entities = const [];
        _entity = null;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.strings;
    final catalog = _catalog;
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(text.title),
        leading: CupertinoButton(
          key: const ValueKey('presence-setup-close'),
          padding: EdgeInsets.zero,
          onPressed: _saving ? null : widget.onFinished,
          child: const Icon(CupertinoIcons.back),
        ),
      ),
      child: SafeArea(
        child: _loading && catalog == null
            ? const Center(child: CupertinoActivityIndicator())
            : ListView(
                padding: const EdgeInsets.only(bottom: 48),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(text.description),
                  ),
                  if (_failed)
                    Semantics(
                      liveRegion: true,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Text(text.failed),
                      ),
                    ),
                  CupertinoFormSection.insetGrouped(
                    children: [
                      if (catalog == null || catalog.services.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(text.noService),
                        )
                      else
                        _PickerRow(
                          key: const ValueKey('presence-setup-service'),
                          label: text.service,
                          value: _service?.name,
                          choose: text.choose,
                          onTap: () async {
                            final value = await _pick(
                              text.service,
                              catalog.services,
                              (item) => item.name,
                            );
                            if (value == null || !mounted) return;
                            setState(() => _service = value);
                            await _loadEntities(value, null);
                          },
                        ),
                      _PickerRow(
                        key: const ValueKey('presence-setup-entity'),
                        label: text.source,
                        value: _entity?.name,
                        choose: text.choose,
                        onTap: _entities.isEmpty
                            ? null
                            : () async {
                                final value = await _pick(
                                  text.source,
                                  _entities,
                                  (item) => '${item.name} · ${item.entityId}',
                                );
                                if (value != null && mounted) {
                                  setState(() => _entity = value);
                                }
                              },
                      ),
                      _PickerRow(
                        key: const ValueKey('presence-setup-room'),
                        label: text.room,
                        value: _room?.label,
                        choose: text.choose,
                        onTap: catalog == null || catalog.rooms.isEmpty
                            ? null
                            : () async {
                                final value = await _pick(
                                  text.room,
                                  catalog.rooms,
                                  (item) => item.label,
                                );
                                if (value != null && mounted) {
                                  setState(() => _room = value);
                                }
                              },
                      ),
                      CupertinoTextFormFieldRow(
                        key: const ValueKey('presence-setup-max-age'),
                        controller: _maxAge,
                        prefix: Text(text.maxAge),
                        keyboardType: TextInputType.number,
                        enabled: !_saving,
                      ),
                      CupertinoFormRow(
                        prefix: Expanded(child: Text(text.consent)),
                        helper: Text(text.consentHint),
                        child: CupertinoSwitch(
                          key: const ValueKey('presence-setup-consent'),
                          value: _consent,
                          onChanged: _saving
                              ? null
                              : (value) => setState(() => _consent = value),
                        ),
                      ),
                    ],
                  ),
                  if (catalog?.configuration?.consentActive == false)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Text(text.revoked),
                    ),
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: CupertinoButton.filled(
                      key: const ValueKey('presence-setup-save'),
                      onPressed: _saving || _loading ? null : _save,
                      child: _saving
                          ? const CupertinoActivityIndicator()
                          : Text(text.save),
                    ),
                  ),
                  if (catalog?.configuration?.consentActive == true)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: CupertinoButton(
                        key: const ValueKey('presence-setup-revoke'),
                        onPressed: _saving ? null : _revoke,
                        child: Text(text.revoke),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

class _PickerRow extends StatelessWidget {
  const _PickerRow({
    super.key,
    required this.label,
    required this.value,
    required this.choose,
    required this.onTap,
  });
  final String label, choose;
  final String? value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => CupertinoButton(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    onPressed: onTap,
    child: Row(
      children: [
        Expanded(child: Text(label, textAlign: TextAlign.start)),
        Flexible(child: Text(value ?? choose, textAlign: TextAlign.end)),
        const SizedBox(width: 6),
        const Icon(CupertinoIcons.chevron_forward, size: 16),
      ],
    ),
  );
}
