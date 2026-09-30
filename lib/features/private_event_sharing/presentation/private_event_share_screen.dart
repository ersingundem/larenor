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
  final _accessToken = TextEditingController();
  final _purpose = TextEditingController();
  static const _masks = <EventShareMask>{
    EventShareMask.face,
    EventShareMask.licensePlate,
  };
  static const _metadata = <EventShareMetadata>{
    EventShareMetadata.deviceSerial,
    EventShareMetadata.gps,
    EventShareMetadata.cameraName,
    EventShareMetadata.networkAddress,
  };
  EventShareAccessMode _mode = EventShareAccessMode.oneTime;
  int _ttl = 3600;
  bool _revealCreatedToken = false;
  bool _consentConfirmed = false;
  String? _selectedRecipient;
  int? _setupRevision;

  @override
  void initState() {
    super.initState();
    _accessToken.addListener(_changed);
    _purpose.addListener(_changed);
    widget.controller.addListener(_changed);
    widget.controller.load();
  }

  void _changed() {
    final setup = widget.controller.setupResult;
    if (setup != null && _setupRevision != setup.policy.revision) {
      _setupRevision = setup.policy.revision;
      String? configuredRecipient;
      for (final id in setup.policy.recipientIds) {
        if (setup.members.any((member) => member.id == id)) {
          configuredRecipient = id;
          break;
        }
      }
      String? otherRecipient;
      for (final member in setup.members) {
        if (member.id != setup.currentUserId) {
          otherRecipient = member.id;
          break;
        }
      }
      _selectedRecipient =
          configuredRecipient ?? otherRecipient ?? setup.currentUserId;
      if (_purpose.text.trim().isEmpty && setup.policy.purposes.isNotEmpty) {
        _purpose.text = setup.policy.purposes.first;
      }
      if (setup.policy.accessModes.length == 1) {
        _mode = setup.policy.accessModes.single;
      }
      if (const {3600, 86400, 604800}.contains(setup.policy.maxTtlSeconds)) {
        _ttl = setup.policy.maxTtlSeconds;
      }
      _consentConfirmed = false;
    }
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
    _accessToken.removeListener(_changed);
    _purpose.removeListener(_changed);
    _accessToken.dispose();
    _purpose.dispose();
    super.dispose();
  }

  PrivateEventSharePolicyDraft? get _policyDraft {
    final recipient = _selectedRecipient;
    final purpose = _purpose.text.trim();
    if (recipient == null || purpose.isEmpty || purpose.length > 200) {
      return null;
    }
    return PrivateEventSharePolicyDraft(
      recipientId: recipient,
      purpose: purpose,
      ttlSeconds: _ttl,
      accessMode: _mode,
    );
  }

  EventShareDraft? get _draft {
    final policy = _policyDraft;
    if (policy == null) return null;
    return widget.controller.consentResult?.draftFor(policy);
  }

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
          _Panel(title: _l10n.privateEventShareSetupTitle, child: _editor()),
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
      Text(
        _l10n.privateEventShareFullFrameExplanation,
        key: const ValueKey('private-event-full-frame-explanation'),
      ),
      const SizedBox(height: 12),
      Text(
        _l10n.privateEventShareRecipientPurpose,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 6),
      _members(),
      const SizedBox(height: 10),
      CupertinoTextField(
        key: const ValueKey('private-event-purpose'),
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
        _l10n.privateEventShareFullFrameCoverage,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      Text(_l10n.privateEventShareMasks(_masks.map(_maskLabel).join(', '))),
      const SizedBox(height: 14),
      Text(
        _l10n.privateEventShareRemoveMetadata,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      Text(
        _l10n.privateEventShareRemovedMetadata(
          _metadata.map(_metadataLabel).join(', '),
        ),
      ),
      const SizedBox(height: 14),
      CupertinoButton.filled(
        key: const ValueKey('private-event-save-policy'),
        onPressed: _policyDraft == null || !_ready
            ? null
            : () => widget.controller.configurePolicy(_policyDraft!),
        child: Text(_l10n.privateEventShareSavePolicy),
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          CupertinoSwitch(
            key: const ValueKey('private-event-consent-switch'),
            value: _consentConfirmed,
            onChanged: _policyMatches && _ready
                ? (value) => setState(() => _consentConfirmed = value)
                : null,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(_l10n.privateEventShareConsentExplanation)),
        ],
      ),
      CupertinoButton(
        key: const ValueKey('private-event-record-consent'),
        onPressed: !_consentConfirmed || !_policyMatches || !_ready
            ? null
            : () => widget.controller.acceptConsent(_policyDraft!),
        child: Text(_l10n.privateEventShareRecordConsent),
      ),
      if (_draft != null)
        Text(
          _l10n.privateEventShareConsentRecorded,
          key: const ValueKey('private-event-consent-recorded'),
        ),
      const SizedBox(height: 10),
      CupertinoButton.filled(
        key: const ValueKey('private-event-create-preview'),
        onPressed: _draft == null || !_ready
            ? null
            : () => widget.controller.preview(_draft!),
        child: Text(_l10n.privateEventShareCreatePreview),
      ),
    ],
  );

  bool get _policyMatches {
    final setup = widget.controller.setupResult;
    final draft = _policyDraft;
    if (setup == null || draft == null) return false;
    final policy = setup.policy;
    return policy.configured &&
        policy.active &&
        policy.fullFrameOnly &&
        policy.grantorIds.contains(setup.currentUserId) &&
        policy.recipientIds.contains(draft.recipientId) &&
        policy.purposes.contains(draft.purpose) &&
        policy.accessModes.contains(draft.accessMode) &&
        policy.maxTtlSeconds >= draft.ttlSeconds &&
        policy.requiredMasks.containsAll(_masks) &&
        policy.requiredMetadata.containsAll(_metadata);
  }

  Widget _members() {
    final setup = widget.controller.setupResult;
    if (setup == null) return Text(_l10n.privateEventShareSetupUnavailable);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final member in setup.members)
          CupertinoButton(
            key: ValueKey('private-event-recipient-${member.id}'),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            color: _selectedRecipient == member.id
                ? CupertinoColors.activeBlue
                : CupertinoColors.systemGrey5,
            onPressed: _ready
                ? () => setState(() {
                    _selectedRecipient = member.id;
                    _consentConfirmed = false;
                  })
                : null,
            child: Text(member.username),
          ),
      ],
    );
  }

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
