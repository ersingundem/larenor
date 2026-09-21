import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../media/hub/presentation/media_session_state.dart';
import '../domain/kiosk_hid_scan_session.dart';

/// Opt-in USB/Bluetooth HID keyboard capture. No scanned value leaves this
/// route or becomes an action, URL, JavaScript message or persisted setting.
class KioskHidScanScreen extends ConsumerStatefulWidget {
  const KioskHidScanScreen({super.key, this.now});

  final DateTime Function()? now;

  @override
  ConsumerState<KioskHidScanScreen> createState() => _KioskHidScanScreenState();
}

class _KioskHidScanScreenState extends MediaSessionState<KioskHidScanScreen> {
  final _session = KioskHidScanSession();
  final _keyboard = FocusNode(debugLabel: 'kiosk-hid-scanner');
  Timer? _clock;
  bool _visible = true;
  DateTime _now() => widget.now?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    _keyboard.addListener(_focusChanged);
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (!_current(sessionGeneration)) {
        _retire();
        return;
      }
      final previous = _session.state;
      _session.expire(_now());
      if (previous != _session.state) setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    if (!_visible || ModalRoute.of(context)?.isCurrent == false) {
      _session.stop();
    }
  }

  bool _current(int generation) =>
      sessionCurrent(generation) &&
      _visible &&
      ModalRoute.of(context)?.isCurrent == true;

  void _focusChanged() {
    if (!mounted ||
        _keyboard.hasFocus ||
        _session.state != HidScanState.scanning) {
      return;
    }
    setState(_session.stop);
  }

  @override
  void clearPendingInteraction() => _session.stop();

  void _retire() {
    if (_session.state == HidScanState.inactive) return;
    setState(_session.stop);
  }

  void _start() {
    if (!_current(sessionGeneration)) return;
    final epoch = sessionGeneration;
    setState(() => _session.start(_now()));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _current(epoch) &&
          _session.state == HidScanState.scanning) {
        _keyboard.requestFocus();
      }
    });
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        !_current(sessionGeneration) ||
        !_keyboard.hasFocus ||
        _session.state != HidScanState.scanning) {
      return KeyEventResult.ignored;
    }
    setState(() {
      if (event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.numpadEnter) {
        _session.finish(_now());
      } else if (event.logicalKey == LogicalKeyboardKey.escape) {
        _session.stop();
      } else {
        _session.feed(event.character, _now());
      }
    });
    return KeyEventResult.handled;
  }

  String _status(AppLocalizations l) => switch (_session.state) {
    HidScanState.inactive => l.kioskHidInactive,
    HidScanState.scanning => l.kioskHidScanning,
    HidScanState.captured => l.kioskHidCaptured(_session.length),
    HidScanState.duplicate => l.kioskHidDuplicate,
    HidScanState.invalid => l.kioskHidInvalid,
    HidScanState.tooLong => l.kioskHidTooLong,
    HidScanState.expired => l.kioskHidExpired,
  };

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final current = _current(sessionGeneration);
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(l.kioskHidTitle)),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(l.kioskHidIntro, style: AppText.body),
                const SizedBox(height: 16),
                SettingsSection(
                  header: Semantics(header: true, child: Text(l.kioskHidTitle)),
                  footer: Text(l.kioskHidPrivacy),
                  children: [
                    Focus(
                      focusNode: _keyboard,
                      onKeyEvent: _key,
                      child: Semantics(
                        key: const ValueKey('kiosk-hid-status'),
                        liveRegion: true,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(_status(l)),
                        ),
                      ),
                    ),
                    CupertinoButton(
                      key: const ValueKey('kiosk-hid-start'),
                      minimumSize: const Size.fromHeight(48),
                      onPressed:
                          current && _session.state != HidScanState.scanning
                          ? _start
                          : null,
                      child: Text(l.kioskHidStart),
                    ),
                    CupertinoButton(
                      key: const ValueKey('kiosk-hid-stop'),
                      minimumSize: const Size.fromHeight(48),
                      onPressed:
                          current && _session.state != HidScanState.inactive
                          ? () => setState(_session.stop)
                          : null,
                      child: Text(l.kioskHidStop),
                    ),
                    if (_session.state == HidScanState.captured) ...[
                      CupertinoButton(
                        key: const ValueKey('kiosk-hid-review'),
                        minimumSize: const Size.fromHeight(48),
                        onPressed: current
                            ? () => setState(_session.reveal)
                            : null,
                        child: Text(l.kioskHidReview),
                      ),
                      if (_session.reviewedValue case final value?)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            value,
                            key: const ValueKey('kiosk-hid-value'),
                          ),
                        ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _clock?.cancel();
    _keyboard.removeListener(_focusChanged);
    _keyboard.dispose();
    _session.stop();
    super.dispose();
  }
}
