import 'package:flutter/cupertino.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/settings_section.dart';
import '../domain/kiosk_peripheral_contract.dart';
import '../data/kiosk_peripheral_runtime.dart';

export '../data/kiosk_peripheral_runtime.dart'
    show
        KioskPeripheralRuntime,
        KioskPeripheralRuntimeSnapshot,
        KioskPeripheralOptInStore;

class KioskPeripheralScreen extends StatefulWidget {
  const KioskPeripheralScreen({super.key, this.runtime, this.optInStore});

  final KioskPeripheralRuntime? runtime;
  final KioskPeripheralOptInStore? optInStore;

  @override
  State<KioskPeripheralScreen> createState() => _KioskPeripheralScreenState();
}

class _KioskPeripheralScreenState extends State<KioskPeripheralScreen>
    with WidgetsBindingObserver {
  late final KioskPeripheralRuntime _runtime;
  late final KioskPeripheralOptInStore _store;
  final KioskPeripheralInputGate _gate = KioskPeripheralInputGate();
  KioskPeripheralInventory? _inventory;
  KioskPeripheralAuthority? _authority;
  Set<String> _optedIn = {};
  KioskPeripheralInput? _review;
  bool _loading = false;
  bool _busy = false;
  bool _foreground = true;
  bool _error = false;
  int _epoch = 0;
  AppInteractionController? _interaction;
  int _interactionEpoch = 0;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    _runtime = widget.runtime ?? AndroidKioskPeripheralRuntime();
    _store = widget.optInStore ?? const LocalKioskPeripheralOptInStore();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _foreground = false;
      _retire();
    } else {
      _foreground = true;
      _refresh();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = AppInteractionScope.maybeOf(context);
    if (!identical(next, _interaction)) {
      _interaction?.removeListener(_interactionChanged);
      final hadInteraction = _interaction != null;
      _interaction = next;
      _interactionEpoch = next?.epoch ?? 0;
      next?.addListener(_interactionChanged);
      if (hadInteraction || next?.active == false) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _retire();
        });
      }
    }
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible != _visible) {
      _visible = visible;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (visible) {
          _refresh();
        } else {
          _retire();
        }
      });
    }
  }

  void _interactionChanged() {
    final interaction = _interaction;
    if (interaction == null) return;
    if (!interaction.active || interaction.epoch != _interactionEpoch) {
      _interactionEpoch = interaction.epoch;
      _retire();
    } else {
      _refresh();
    }
  }

  bool _current(int epoch) =>
      mounted &&
      epoch == _epoch &&
      _foreground &&
      (_interaction == null ||
          (_interaction!.active && _interaction!.epoch == _interactionEpoch)) &&
      TickerMode.valuesOf(context).enabled &&
      ModalRoute.of(context)?.isCurrent == true;

  void _retire() {
    _epoch++;
    _review = null;
    _authority = null;
    _inventory = null;
    _busy = false;
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    if (!mounted ||
        !_foreground ||
        !TickerMode.valuesOf(context).enabled ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final epoch = ++_epoch;
    setState(() {
      _loading = true;
      _error = false;
      _review = null;
      _inventory = null;
      _authority = null;
    });
    try {
      final optedIn = await _store.read();
      final snapshot = await _runtime.snapshot();
      if (!_current(epoch)) return;
      final raw = snapshot.rawInventory;
      if (raw is! Map || raw['providers'] is! List) {
        throw const FormatException('invalid peripheral inventory');
      }
      final providers = <Map<String, Object?>>[];
      for (final item in raw['providers'] as List) {
        if (item is! Map || item['providerId'] is! String) {
          throw const FormatException('invalid peripheral provider');
        }
        providers.add({
          ...item.cast<String, Object?>(),
          'enabledByUser': optedIn.contains(item['providerId']),
        });
      }
      final inventory = KioskPeripheralInventory.fromChannel({
        ...raw.cast<String, Object?>(),
        'providers': providers,
      }, gmsAvailable: snapshot.gmsAvailable);
      if (!_current(epoch)) return;
      setState(() {
        _optedIn = optedIn;
        _inventory = inventory;
        _authority = snapshot.authority;
      });
    } catch (_) {
      if (_current(epoch)) setState(() => _error = true);
    } finally {
      if (_current(epoch)) setState(() => _loading = false);
    }
  }

  Future<void> _toggle(KioskPeripheralCapability provider) async {
    final epoch = _epoch;
    if (!_current(epoch) || _busy) return;
    final next = {..._optedIn};
    if (!next.add(provider.providerId)) next.remove(provider.providerId);
    setState(() {
      _busy = true;
      _review = null;
    });
    try {
      await _store.save(next);
      if (_current(epoch)) await _refresh();
    } catch (_) {
      if (_current(epoch)) setState(() => _error = true);
    } finally {
      if (_current(_epoch)) setState(() => _busy = false);
    }
  }

  Future<void> _consume(KioskPeripheralCapability provider) async {
    final epoch = _epoch;
    final authority = _authority;
    if (!_current(epoch) ||
        _busy ||
        authority == null ||
        !provider.acceptsInput) {
      return;
    }
    setState(() {
      _busy = true;
      _review = null;
      _error = false;
    });
    try {
      final raw = await _runtime.takeNextInput(provider.providerId);
      if (!_current(epoch)) return;
      if (raw == null) throw const FormatException('no peripheral input');
      final input = _gate.accept(
        raw,
        inventory: _inventory!,
        expectedAuthority: authority,
        isCurrent: () => _current(epoch) && identical(_authority, authority),
        nowElapsedMs: _runtime.nowElapsedMs(),
      );
      if (input.providerId != provider.providerId || !_current(epoch)) return;
      setState(() => _review = input);
    } catch (_) {
      if (_current(epoch)) setState(() => _error = true);
    } finally {
      if (_current(epoch)) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _interaction?.removeListener(_interactionChanged);
    _epoch++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final inventory = _inventory;
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l.kioskPeripheralTitle),
      ),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 740),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(l.kioskPeripheralHint, style: AppText.body),
                  ),
                  if (_loading)
                    const Center(child: CupertinoActivityIndicator()),
                  if (_error)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(l.kioskPeripheralUnavailable),
                    ),
                  if (inventory != null)
                    SettingsSection(
                      header: Semantics(
                        header: true,
                        child: Text(l.kioskPeripheralTitle),
                      ),
                      children: [
                        for (final provider in inventory.providers)
                          _providerRow(l, provider),
                      ],
                    ),
                  if (_review != null)
                    SettingsSection(
                      header: Semantics(
                        key: const ValueKey('peripheral-review-only'),
                        header: true,
                        child: Text(l.kioskPeripheralReviewOnly),
                      ),
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            _review!.payload,
                            textDirection: TextDirection.ltr,
                          ),
                        ),
                      ],
                    ),
                  CupertinoButton(
                    key: const ValueKey('peripheral-refresh'),
                    minimumSize: const Size(48, 48),
                    onPressed: !_busy && !_loading && _current(_epoch)
                        ? _refresh
                        : null,
                    child: Text(l.commonRefresh),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _providerRow(AppLocalizations l, KioskPeripheralCapability provider) {
    final enabled = _optedIn.contains(provider.providerId);
    final canConsume = provider.acceptsInput && _authority != null && !_busy;
    final title = switch (provider.kind) {
      KioskPeripheralKind.qr => l.kioskPeripheralQr,
      KioskPeripheralKind.nfc => l.kioskPeripheralNfc,
      KioskPeripheralKind.ble => l.kioskPeripheralBle,
      KioskPeripheralKind.usb => l.kioskPeripheralUsb,
      KioskPeripheralKind.tts => l.kioskPeripheralTts,
      KioskPeripheralKind.print => l.kioskPeripheralPrint,
    };
    final status = switch (provider.availability) {
      KioskPeripheralAvailability.ready => l.kioskPeripheralReady,
      KioskPeripheralAvailability.disabled => l.kioskPeripheralDisabled,
      KioskPeripheralAvailability.unsupported => l.kioskPeripheralUnsupported,
      KioskPeripheralAvailability.permissionDenied => l.kioskPeripheralDenied,
      KioskPeripheralAvailability.permissionUnknown =>
        l.kioskPeripheralPermissionUnknown,
      KioskPeripheralAvailability.disconnected => l.kioskPeripheralDisconnected,
      KioskPeripheralAvailability.gmsUnavailable =>
        l.kioskPeripheralGmsUnavailable,
    };
    final choice = enabled
        ? l.kioskPeripheralChoiceEnabled
        : l.kioskPeripheralDisabled;
    final permission = switch (provider.permission) {
      KioskPeripheralPermission.notRequired =>
        l.kioskPeripheralPermissionNotRequired,
      KioskPeripheralPermission.granted => l.kioskPeripheralPermissionGranted,
      KioskPeripheralPermission.denied => l.kioskPeripheralDenied,
      KioskPeripheralPermission.unknown => l.kioskPeripheralPermissionUnknown,
    };
    final connection = provider.connected
        ? l.kioskPeripheralConnected
        : l.kioskPeripheralDisconnected;
    final details = [
      status,
      choice,
      permission,
      connection,
      if (provider.requiresGms && !provider.gmsAvailable)
        l.kioskPeripheralGmsUnavailable,
    ];
    return Padding(
      key: ValueKey('peripheral-${provider.providerId}'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            container: true,
            label: '$title. ${details.join('. ')}',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: AppText.body),
                for (final detail in details) Text(detail, style: AppText.body),
              ],
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              Semantics(
                label:
                    '$title. ${enabled ? l.kioskPeripheralDisable : l.kioskPeripheralEnable}',
                child: CupertinoButton(
                  key: ValueKey('peripheral-toggle-${provider.providerId}'),
                  minimumSize: const Size(48, 48),
                  onPressed: _busy ? null : () => _toggle(provider),
                  child: Text(
                    enabled
                        ? l.kioskPeripheralDisable
                        : l.kioskPeripheralEnable,
                  ),
                ),
              ),
              if (canConsume)
                Semantics(
                  label: '$title. ${l.kioskPeripheralReviewInput}',
                  child: CupertinoButton(
                    key: ValueKey('peripheral-consume-${provider.providerId}'),
                    minimumSize: const Size(48, 48),
                    onPressed: () => _consume(provider),
                    child: Text(l.kioskPeripheralReviewInput),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
