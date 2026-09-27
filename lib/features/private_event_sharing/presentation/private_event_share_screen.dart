import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

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

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
    navigationBar: const CupertinoNavigationBar(
      middle: Text('Private event sharing'),
    ),
    child: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Panel(title: 'Recipient and purpose', child: _editor()),
          const SizedBox(height: 16),
          _Panel(title: 'Redaction preview', child: _preview()),
          const SizedBox(height: 16),
          _Panel(title: 'Active and previous shares', child: _shares()),
          const SizedBox(height: 16),
          _Panel(title: 'Access audit', child: _audit()),
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
        placeholder: 'Exact consent ID',
      ),
      const SizedBox(height: 10),
      CupertinoTextField(
        controller: _consentRevision,
        keyboardType: TextInputType.number,
        placeholder: 'Consent revision',
      ),
      const SizedBox(height: 10),
      CupertinoTextField(
        controller: _recipient,
        maxLength: 128,
        placeholder: 'Exact recipient ID',
      ),
      const SizedBox(height: 10),
      CupertinoTextField(
        controller: _purpose,
        maxLength: 200,
        placeholder: 'Purpose shown to the recipient',
      ),
      const SizedBox(height: 12),
      CupertinoSlidingSegmentedControl<EventShareAccessMode>(
        groupValue: _mode,
        children: const {
          EventShareAccessMode.oneTime: Text('One time'),
          EventShareAccessMode.timeBound: Text('Until expiry'),
        },
        onValueChanged: (value) => setState(() => _mode = value ?? _mode),
      ),
      const SizedBox(height: 12),
      CupertinoSlidingSegmentedControl<int>(
        groupValue: _ttl,
        children: const {
          3600: Text('1 hour'),
          86400: Text('1 day'),
          604800: Text('7 days'),
        },
        onValueChanged: (value) => setState(() => _ttl = value ?? _ttl),
      ),
      const SizedBox(height: 14),
      const Text(
        'Required masks',
        style: TextStyle(fontWeight: FontWeight.w600),
      ),
      _choices<EventShareMask>(
        values: EventShareMask.values,
        selected: _masks,
        label: (value) => switch (value) {
          EventShareMask.face => 'Faces',
          EventShareMask.licensePlate => 'License plates',
        },
      ),
      const SizedBox(height: 14),
      const Text(
        'Remove metadata',
        style: TextStyle(fontWeight: FontWeight.w600),
      ),
      _choices<EventShareMetadata>(
        values: EventShareMetadata.values,
        selected: _metadata,
        label: (value) => switch (value) {
          EventShareMetadata.deviceSerial => 'Device serial',
          EventShareMetadata.gps => 'GPS',
          EventShareMetadata.cameraName => 'Camera name',
          EventShareMetadata.networkAddress => 'Network address',
        },
      ),
      const SizedBox(height: 14),
      CupertinoButton.filled(
        onPressed: _draft == null || !_ready
            ? null
            : () => widget.controller.preview(_draft!),
        child: const Text('Create protected preview'),
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
        const Text(
          'The original stays private. Only the transformed artifact is shared.',
        ),
        const SizedBox(height: 8),
        Text('Pipeline: ${preview.pipelineId} r${preview.pipelineRevision}'),
        Text('Masks: ${preview.masks.map((value) => value.name).join(', ')}'),
        Text(
          'Removed metadata: ${preview.removedMetadata.map((value) => value.name).join(', ')}',
        ),
        const SizedBox(height: 12),
        CupertinoButton.filled(
          onPressed: draft == null || !preview.covers(draft) || !_ready
              ? null
              : () => widget.controller.create(draft),
          child: const Text('Share this protected output'),
        ),
      ],
    );
  }

  Widget _shares() {
    final shares = widget.controller.snapshot?.shares ?? const [];
    return Column(
      children: [
        if (widget.controller.createdShare case final created?) ...[
          const Text(
            'Share access token',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const Text(
            'Save and send this token through a trusted channel. It is not returned by later refreshes.',
          ),
          CupertinoButton(
            onPressed: () =>
                setState(() => _revealCreatedToken = !_revealCreatedToken),
            child: Text(_revealCreatedToken ? 'Hide token' : 'Reveal token'),
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
              child: const Text('Copy token'),
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
                Text('Recipient: ${share.recipientId}'),
                Text('Expires: ${share.expiresAt.toLocal()}'),
                Text(
                  share.revoked
                      ? 'Revoked'
                      : share.consumed
                      ? 'Consumed'
                      : 'Available',
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: CupertinoButton(
                        onPressed: share.active && _ready
                            ? () => widget.controller.revoke(share.id)
                            : null,
                        child: const Text('Revoke'),
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
          placeholder: 'Recipient access token',
        ),
        CupertinoButton(
          onPressed: _ready && _accessToken.text.length >= 32
              ? () => widget.controller.download(_accessToken.text)
              : null,
          child: const Text('Download protected share'),
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
          const Text(
            'Only the latest access records are shown.',
            style: TextStyle(color: CupertinoColors.systemOrange),
          ),
        if (entries.isEmpty) const Text('No access recorded'),
        for (final entry in entries)
          Text(
            '${entry.action} · ${entry.recipientId} · ${entry.occurredAt.toLocal()}',
          ),
        if (widget.controller.downloadResult case final download?) ...[
          const SizedBox(height: 12),
          Text(
            'Verified download ready: ${download.fileName} (${download.bytes.length} bytes)',
          ),
        ],
      ],
    );
  }

  Widget _status() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(switch (widget.controller.state) {
        EventShareState.idle => 'Not connected',
        EventShareState.loading => 'Loading',
        EventShareState.ready => 'No items yet',
        EventShareState.busy => 'Working',
        EventShareState.uncertain =>
          'Result uncertain; refresh before retrying',
        EventShareState.offline => 'Core unavailable',
        EventShareState.error => 'State could not be verified',
      }),
      if (widget.controller.state == EventShareState.uncertain)
        CupertinoButton(
          onPressed: widget.controller.reconcile,
          child: const Text('Read current state'),
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
