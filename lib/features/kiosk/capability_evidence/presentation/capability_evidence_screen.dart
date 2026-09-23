import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/service_root_scaffold.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../../../server/data/server_account_controller.dart';
import '../../../server/providers/server_providers.dart';
import '../data/capability_evidence_api.dart';
import '../domain/capability_evidence_models.dart';

typedef EvidenceLoad = Future<List<CapabilityEvidenceRecord>> Function();

final class CapabilityEvidenceController extends ChangeNotifier {
  CapabilityEvidenceController({required this._load, required this._current});
  final EvidenceLoad _load;
  final bool Function() _current;
  int _epoch = 0;
  bool _disposed = false;
  bool busy = false, loaded = false, failed = false;
  int loadCount = 0;
  List<CapabilityEvidenceRecord> records = const [];

  Future<void> refresh() async {
    if (_disposed || busy || !_current()) return;
    final epoch = ++_epoch;
    busy = true;
    loaded = false;
    failed = false;
    records = const [];
    loadCount++;
    notifyListeners();
    try {
      final value = await _load();
      if (_valid(epoch)) {
        records = List.unmodifiable(value);
        loaded = true;
      }
    } catch (_) {
      if (_valid(epoch)) failed = true;
    } finally {
      if (_valid(epoch)) {
        busy = false;
        notifyListeners();
      }
    }
  }

  bool _valid(int epoch) => !_disposed && epoch == _epoch && _current();
  void invalidate() {
    if (_disposed) return;
    _epoch++;
    busy = false;
    loaded = false;
    failed = false;
    records = const [];
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    super.dispose();
  }
}

final class CapabilityEvidenceScreen extends StatefulWidget {
  const CapabilityEvidenceScreen({super.key, required this.controller});
  final CapabilityEvidenceController controller;
  @override
  State<CapabilityEvidenceScreen> createState() =>
      _CapabilityEvidenceScreenState();
}

final class _CapabilityEvidenceScreenState
    extends State<CapabilityEvidenceScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controller.refresh();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) widget.controller.invalidate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.invalidate();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) => ServiceRootScaffold(
        title: l.kioskEvidenceTitle,
        trailing: OverflowBox(
          minWidth: 48,
          maxWidth: 48,
          minHeight: 48,
          maxHeight: 48,
          child: CupertinoButton(
            key: const ValueKey('capability-evidence-refresh'),
            minimumSize: const Size(48, 48),
            padding: EdgeInsets.zero,
            onPressed: widget.controller.busy
                ? null
                : widget.controller.refresh,
            child: Semantics(
              label: l.commonRefresh,
              button: true,
              child: const Icon(CupertinoIcons.refresh),
            ),
          ),
        ),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text(l.kioskEvidenceIntro),
            ),
          ),
          if (widget.controller.busy)
            const SliverFilledMessage(child: CupertinoActivityIndicator())
          else if (widget.controller.failed)
            SliverFilledMessage(child: Text(l.kioskEvidenceUnavailable))
          else if (!widget.controller.loaded ||
              widget.controller.records.isEmpty)
            SliverFilledMessage(child: Text(l.kioskEvidenceEmpty))
          else
            SliverList.builder(
              itemCount: widget.controller.records.length,
              itemBuilder: (context, index) {
                final record = widget.controller.records[index];
                final label = switch (record.outcome) {
                  CapabilityEvidenceOutcome.tested => l.kioskEvidenceTested,
                  CapabilityEvidenceOutcome.failed => l.kioskEvidenceFailed,
                  CapabilityEvidenceOutcome.untested => l.kioskEvidenceUntested,
                  CapabilityEvidenceOutcome.manualRequired =>
                    l.kioskEvidenceManual,
                };
                return SettingsSection(
                  header: Semantics(
                    header: true,
                    child: Text(record.capabilityId),
                  ),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(record.oem),
                          Text(record.model),
                          Text(
                            l.kioskEvidenceEnvironment(
                              record.androidApi,
                              record.webViewPackage,
                              record.webViewVersion,
                              record.dexProfile,
                            ),
                          ),
                          Text(record.permissions.join(', ')),
                          Semantics(
                            key: ValueKey(
                              'capability-evidence-${record.outcome.wireName.replaceAll('_', '-')}',
                            ),
                            label: label,
                            child: Text(label),
                          ),
                          Text(record.artifactName),
                          Text(
                            l.kioskEvidenceTrace(
                              record.sourceCommit,
                              record.testCase,
                              record.revision,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }
}

/// Production entry uses the existing authenticated account and Settings PIN.
final class CapabilityEvidenceRoute extends ConsumerStatefulWidget {
  const CapabilityEvidenceRoute({super.key, required this.gateCurrent});
  final bool Function() gateCurrent;
  @override
  ConsumerState<CapabilityEvidenceRoute> createState() =>
      _CapabilityEvidenceRouteState();
}

final class _CapabilityEvidenceRouteState
    extends ConsumerState<CapabilityEvidenceRoute>
    with WidgetsBindingObserver {
  late final ServerAccountController account;
  late final int generation;
  late final String? userId, endpoint;
  late final Object? contextIdentity;
  late final CapabilityEvidenceController controller;
  bool _visible = true;
  ValueListenable<TickerModeData>? _ticker;

  bool get _current {
    final session = account.session;
    return mounted &&
        _visible &&
        (_ticker?.value.enabled ?? true) &&
        widget.gateCurrent() &&
        (ModalRoute.of(context)?.isCurrent ?? true) &&
        account.isCurrent(generation) &&
        account.initialized &&
        !account.working &&
        session?.user.canAdminister == true &&
        session?.user.id == userId &&
        session?.endpoint.baseUrl == endpoint &&
        session?.context == contextIdentity;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    account = ref.read(serverAccountControllerProvider);
    generation = account.generation;
    userId = account.session?.user.id;
    endpoint = account.session?.endpoint.baseUrl;
    contextIdentity = account.session?.context;
    controller = CapabilityEvidenceController(
      load: () async {
        final records = await account.withSession((api, session) async {
          if (!_current || session.context != contextIdentity) {
            return <CapabilityEvidenceRecord>[];
          }
          return CapabilityEvidenceApi(
            api,
            session.accessToken,
            session.context!,
          ).list();
        });
        if (!_current) return const [];
        return records;
      },
      current: () => _current,
    );
    account.addListener(_accountChanged);
  }

  void _accountChanged() {
    if (!_current) {
      controller.invalidate();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _visible = state == AppLifecycleState.resumed;
    if (!_visible) controller.invalidate();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ticker = TickerMode.getValuesNotifier(context);
    if (!identical(ticker, _ticker)) {
      _ticker?.removeListener(_tickerChanged);
      _ticker = ticker;
      ticker.addListener(_tickerChanged);
    }
    if (!ticker.value.enabled) controller.invalidate();
  }

  void _tickerChanged() {
    if (_ticker?.value.enabled != true) controller.invalidate();
  }

  @override
  void dispose() {
    account.removeListener(_accountChanged);
    _ticker?.removeListener(_tickerChanged);
    WidgetsBinding.instance.removeObserver(this);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      CapabilityEvidenceScreen(controller: controller);
}
