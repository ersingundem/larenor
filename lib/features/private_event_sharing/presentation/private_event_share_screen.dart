import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../data/private_event_share_controller.dart';
import '../domain/private_event_share_models.dart';

class PrivateEventShareScreen extends StatefulWidget {
  const PrivateEventShareScreen({super.key, required this.controller});

  final PrivateEventShareController controller;

  @override
  State<PrivateEventShareScreen> createState() =>
      _PrivateEventShareScreenState();
}

class _PrivateEventShareScreenState extends State<PrivateEventShareScreen> {
  final _recipient = TextEditingController();
  final _consent = TextEditingController();
  final _consentRevision = TextEditingController(text: '1');
  final _accessToken = TextEditingController();
  final _purpose = TextEditingController();
  final _masks = <EventShareMask>{EventShareMask.face};
  final _metadata = <EventShareMetadata>{
    EventShareMetadata.deviceSerial,
    EventShareMetadata.gps,
    EventShareMetadata.cameraName,
    EventShareMetadata.networkAddress,
  };
  EventShareAccessMode _mode = EventShareAccessMode.oneTime;
  int _ttl = 3600;
  bool _revealCreatedToken = false;

  @override
  void initState() {
    super.initState();
    _recipient.addListener(_changed);
    _consent.addListener(_changed);
    _consentRevision.addListener(_changed);
    _accessToken.addListener(_changed);
    _purpose.addListener(_changed);
    widget.controller.addListener(_changed);
    widget.controller.load();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant PrivateEventShareScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      oldWidget.controller.cancel();
      widget.controller.addListener(_changed);
      widget.controller.load();
      _revealCreatedToken = false;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    widget.controller.cancel();
    _recipient.removeListener(_changed);
    _consent.removeListener(_changed);
    _consentRevision.removeListener(_changed);
    _accessToken.removeListener(_changed);
    _purpose.removeListener(_changed);
    _recipient.dispose();
    _consent.dispose();
    _consentRevision.dispose();
    _accessToken.dispose();
    _purpose.dispose();
    super.dispose();
  }

  EventShareDraft? get _draft => EventShareDraft.tryCreate(
    consentId: _consent.text,
    consentRevision: int.tryParse(_consentRevision.text) ?? 0,
    recipientId: _recipient.text,
    purpose: _purpose.text,
    ttlSeconds: _ttl,
    accessMode: _mode,
    masks: _masks,
    removedMetadata: _metadata,
  );

  bool get _ready => widget.controller.state == EventShareState.ready;

  AppLocalizations get _l10n => AppLocalizations.of(context);

  String _maskLabel(EventShareMask value) => switch (value) {
    EventShareMask.face => _l10n.privateEventShareMaskFaces,
    EventShareMask.licensePlate => _l10n.privateEventShareMaskLicensePlates,
  };

  String _metadataLabel(EventShareMetadata value) => switch (value) {
    EventShareMetadata.deviceSerial =>
      _l10n.privateEventShareMetadataDeviceSerial,
    EventShareMetadata.gps => _l10n.privateEventShareMetadataGps,
    EventShareMetadata.cameraName => _l10n.privateEventShareMetadataCameraName,
    EventShareMetadata.networkAddress =>
      _l10n.privateEventShareMetadataNetworkAddress,
  };

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
    navigationBar: CupertinoNavigationBar(
      middle: Text(_l10n.privateEventShareTitle),
    ),
    child: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Panel(
            title: _l10n.privateEventShareRecipientPurpose,
            child: _editor(),
          ),
          const SizedBox(height: 16),
          _Panel(
            title: _l10n.privateEventShareRedactionPreview,
            child: _preview(),
          ),
          const SizedBox(height: 16),
          _Panel(title: _l10n.privateEventShareShares, child: _shares()),
          const SizedBox(height: 16),
          _Panel(title: _l10n.privateEventShareAudit, child: _audit()),
        ],
      ),
    ),
  );

  Widget _editor() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      CupertinoTextField(
        controller: _consent,
        maxLength: 128,
        placeholder: _l10n.privateEventShareConsentId,
      ),
      const SizedBox(height: 10),
      CupertinoTextField(
        controller: _consentRevision,
        keyboardType: TextInputType.number,
        placeholder: _l10n.privateEventShareConsentRevision,
      ),
      const SizedBox(height: 10),
      CupertinoTextField(
        controller: _recipient,
        maxLength: 128,
        placeholder: _l10n.privateEventShareRecipientId,
      ),
      const SizedBox(height: 10),
      CupertinoTextField(
        controller: _purpose,
        maxLength: 200,
        placeholder: _l10n.privateEventSharePurpose,
      ),
      const SizedBox(height: 12),
      CupertinoSlidingSegmentedControl<EventShareAccessMode>(
        groupValue: _mode,
        children: {
          EventShareAccessMode.oneTime: Text(
            _l10n.privateEventShareModeOneTime,
          ),
          EventShareAccessMode.timeBound: Text(
            _l10n.privateEventShareModeUntilExpiry,
          ),
        },
        onValueChanged: (value) => setState(() => _mode = value ?? _mode),
      ),
      const SizedBox(height: 12),
      CupertinoSlidingSegmentedControl<int>(
        groupValue: _ttl,
        children: {
          3600: Text(_l10n.privateEventShareTtlHour),
          86400: Text(_l10n.privateEventShareTtlDay),
          604800: Text(_l10n.privateEventShareTtlWeek),
        },
        onValueChanged: (value) => setState(() => _ttl = value ?? _ttl),
      ),
      const SizedBox(height: 14),
      Text(
        _l10n.privateEventShareRequiredMasks,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      _choices<EventShareMask>(
        values: EventShareMask.values,
        selected: _masks,
        label: _maskLabel,
      ),
      const SizedBox(height: 14),
      Text(
        _l10n.privateEventShareRemoveMetadata,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      _choices<EventShareMetadata>(
        values: EventShareMetadata.values,
        selected: _metadata,
        label: _metadataLabel,
      ),
      const SizedBox(height: 14),
      CupertinoButton.filled(
        onPressed: _draft == null || !_ready
            ? null
            : () => widget.controller.preview(_draft!),
        child: Text(_l10n.privateEventShareCreatePreview),
      ),
    ],
  );

  Widget _choices<T>({
    required List<T> values,
    required Set<T> selected,
    required String Function(T) label,
  }) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final value in values)
        CupertinoButton(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          color: selected.contains(value)
              ? CupertinoColors.activeBlue
              : CupertinoColors.systemGrey5,
          onPressed: () => setState(() {
            if (!selected.remove(value)) selected.add(value);
          }),
          child: Text(label(value)),
        ),
    ],
  );

  Widget _preview() {
    final preview = widget.controller.previewResult;
    final draft = _draft;
    if (preview == null) return _status();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(_l10n.privateEventShareOriginalStaysPrivate),
        const SizedBox(height: 8),
        Text(
          _l10n.privateEventSharePipeline(
            preview.pipelineId,
            preview.pipelineRevision,
          ),
        ),
        Text(
          _l10n.privateEventShareMasks(
            preview.masks.map(_maskLabel).join(', '),
          ),
        ),
        Text(
          _l10n.privateEventShareRemovedMetadata(
            preview.removedMetadata.map(_metadataLabel).join(', '),
          ),
        ),
        const SizedBox(height: 12),
        CupertinoButton.filled(
          onPressed: draft == null || !preview.covers(draft) || !_ready
              ? null
              : () => widget.controller.create(draft),
          child: Text(_l10n.privateEventShareProtectedOutput),
        ),
      ],
    );
  }

  Widget _shares() {
    final shares = widget.controller.snapshot?.shares ?? const [];
    return Column(
      children: [
        if (widget.controller.createdShare case final created?) ...[
          Text(
            _l10n.privateEventShareAccessToken,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          Text(_l10n.privateEventShareAccessTokenHint),
          CupertinoButton(
            onPressed: () =>
                setState(() => _revealCreatedToken = !_revealCreatedToken),
            child: Text(
              _revealCreatedToken
                  ? _l10n.privateEventShareHideToken
                  : _l10n.privateEventShareRevealToken,
            ),
          ),
          if (_revealCreatedToken)
            Text(
              created.accessToken,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          if (_revealCreatedToken)
            CupertinoButton(
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: created.accessToken)),
              child: Text(_l10n.privateEventShareCopyToken),
            ),
          const SizedBox(height: 14),
        ],
        if (shares.isEmpty) _status(),
        for (final share in shares)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  share.purpose,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(_l10n.privateEventShareRecipient(share.recipientId)),
                Text(
                  _l10n.privateEventShareExpires(
                    share.expiresAt.toLocal().toString(),
                  ),
                ),
                Text(
                  share.revoked
                      ? _l10n.privateEventShareRevoked
                      : share.consumed
                      ? _l10n.privateEventShareConsumed
                      : _l10n.privateEventShareAvailable,
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: CupertinoButton(
                        onPressed: share.active && _ready
                            ? () => widget.controller.revoke(share.id)
                            : null,
                        child: Text(_l10n.privateEventShareRevoke),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        CupertinoTextField(
          controller: _accessToken,
          obscureText: true,
          placeholder: _l10n.privateEventShareRecipientAccessToken,
        ),
        CupertinoButton(
          onPressed: _ready && _accessToken.text.length >= 32
              ? () => widget.controller.download(_accessToken.text)
              : null,
          child: Text(_l10n.privateEventShareDownload),
        ),
      ],
    );
  }

  Widget _audit() {
    final entries = widget.controller.snapshot?.audit ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.controller.snapshot?.auditTruncated ?? false)
          Text(
            _l10n.privateEventShareAuditTruncated,
            style: const TextStyle(color: CupertinoColors.systemOrange),
          ),
        if (entries.isEmpty) Text(_l10n.privateEventShareNoAccess),
        for (final entry in entries)
          Text(
            _l10n.privateEventShareAuditEntry(
              entry.action,
              entry.recipientId,
              entry.occurredAt.toLocal().toString(),
            ),
          ),
        if (widget.controller.downloadResult case final download?) ...[
          const SizedBox(height: 12),
          Text(
            _l10n.privateEventShareDownloadReady(
              download.fileName,
              download.bytes.length,
            ),
          ),
        ],
      ],
    );
  }

  Widget _status() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(switch (widget.controller.state) {
        EventShareState.idle => _l10n.privateEventShareNotConnected,
        EventShareState.loading => _l10n.commonLoading,
        EventShareState.ready => _l10n.privateEventShareNoItems,
        EventShareState.busy => _l10n.privateEventShareWorking,
        EventShareState.uncertain => _l10n.privateEventShareUncertain,
        EventShareState.offline => _l10n.privateEventShareCoreUnavailable,
        EventShareState.error => _l10n.privateEventShareStateUnverified,
      }),
      if (widget.controller.state == EventShareState.uncertain)
        CupertinoButton(
          onPressed: widget.controller.reconcile,
          child: Text(_l10n.privateEventShareReadCurrentState),
        ),
      if (widget.controller.state == EventShareState.offline ||
          widget.controller.state == EventShareState.error)
        CupertinoButton(
          key: const ValueKey('private-event-share-retry'),
          onPressed: widget.controller.load,
          child: Text(_l10n.commonRetry),
        ),
    ],
  );
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: CupertinoColors.secondarySystemGroupedBackground,
      borderRadius: BorderRadius.circular(18),
    ),
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    ),
  );
}
