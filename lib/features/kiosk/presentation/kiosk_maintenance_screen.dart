import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/settings_section.dart';
import '../data/kiosk_usage_repository.dart';

final class KioskMaintenanceScreen extends StatefulWidget {
  const KioskMaintenanceScreen({super.key, this.repository});
  final KioskUsageRepository? repository;

  @override
  State<KioskMaintenanceScreen> createState() => _KioskMaintenanceScreenState();
}

final class _KioskMaintenanceScreenState extends State<KioskMaintenanceScreen> {
  late final KioskUsageRepository _repository =
      widget.repository ?? KioskUsageRepository();
  KioskUsageSnapshot? _snapshot;
  String? _csv;
  bool _loading = false;
  bool _failed = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading || !mounted) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _failed = false;
      _snapshot = null;
      _csv = null;
    });
    try {
      final snapshot = await _repository.read();
      final csv = await _repository.csvPreview();
      if (!mounted || generation != _generation) return;
      setState(() {
        _snapshot = snapshot;
        _csv = csv;
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _failed = true);
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final snapshot = _snapshot;
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l.kioskMaintenanceTitle),
      ),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                    child: Text(l.kioskMaintenanceHint, style: AppText.body),
                  ),
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CupertinoActivityIndicator()),
                    )
                  else if (_failed)
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(l.kioskMaintenanceUnavailable),
                      ),
                    )
                  else if (snapshot != null) ...[
                    SettingsSection(
                      header: Semantics(
                        header: true,
                        child: Text(l.kioskMaintenanceThirtyDays),
                      ),
                      children: [
                        _row(
                          l.kioskMaintenanceFailures,
                          snapshot.count(KioskUsageEvent.rendererFailure),
                        ),
                        _row(
                          l.kioskMaintenanceTimeouts,
                          snapshot.count(KioskUsageEvent.timeout),
                        ),
                        _row(
                          l.kioskMaintenanceRecoveries,
                          snapshot.count(KioskUsageEvent.recoveryAttempt),
                        ),
                        _row(
                          l.kioskMaintenanceBlocked,
                          snapshot.count(KioskUsageEvent.recoveryBlocked),
                        ),
                        _row(
                          l.kioskMaintenanceReady,
                          snapshot.count(KioskUsageEvent.ready),
                        ),
                      ],
                    ),
                    SettingsSection(
                      header: Semantics(
                        header: true,
                        child: Text(l.kioskMaintenanceCsvTitle),
                      ),
                      footer: Text(l.kioskMaintenanceCsvHint),
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Semantics(
                            label: l.kioskMaintenanceCsvTitle,
                            readOnly: true,
                            child: SelectableText(
                              _csv!,
                              key: const ValueKey('kiosk-maintenance-csv'),
                              style: AppText.footnote,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: CupertinoButton(
                      key: const ValueKey('kiosk-maintenance-refresh'),
                      minimumSize: const Size.fromHeight(48),
                      onPressed: _loading ? null : _load,
                      child: Text(l.commonRefresh),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      l.kioskMaintenanceBoundary,
                      style: AppText.footnote,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(String label, int value) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Row(
      children: [
        Expanded(child: Text(label, style: AppText.body)),
        const SizedBox(width: 12),
        Text('$value', style: AppText.headline),
      ],
    ),
  );
}
