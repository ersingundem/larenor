import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../auth/providers/auth_providers.dart';
import '../../web_panel/domain/web_panel_policy.dart';
import '../../web_panel/presentation/web_panel_view.dart';
import 'ha_session_guard.dart';

/// The official frontend owns a separate website login. Larenor's long-lived
/// API credential never enters its headers, JavaScript, cookies or URL.
class HaFrontendScreen extends ConsumerStatefulWidget {
  const HaFrontendScreen({super.key});
  @override
  ConsumerState<HaFrontendScreen> createState() => _HaFrontendScreenState();
}

class _HaFrontendScreenState extends HaSessionState<HaFrontendScreen> {
  final _panel = GlobalKey<WebPanelViewState>();
  @override
  void clearPendingInteraction() => _panel.currentState?.suspend();

  Future<void> _back() async {
    final route = ModalRoute.of(context);
    final consumed = await (_panel.currentState?.back() ?? Future.value(false));
    if (!mounted || consumed || route?.isCurrent != true) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    watchHaSession();
    final l10n = AppLocalizations.of(context);
    final current = ref.watch(connectionConfigProvider);
    final config = !current.isLoading && !current.hasError
        ? current.value
        : null;
    final lease = captureHaSession();
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.haFrontend),
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _back,
          child: Semantics(
            label: l10n.commonBack,
            child: const Icon(CupertinoIcons.back),
          ),
        ),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: lease == null
              ? null
              : () {
                  if (isHaSessionCurrent(lease)) _panel.currentState?.restart();
                },
          child: Semantics(
            label: l10n.commonRetry,
            child: const Icon(CupertinoIcons.refresh),
          ),
        ),
      ),
      child: SafeArea(
        child: lease == null || config == null
            ? Center(
                child: Text(
                  sessionExpired
                      ? l10n.mediaSelectionExpired
                      : l10n.haDisconnected,
                ),
              )
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(l10n.webPanelSeparateSession),
                  ),
                  Expanded(
                    child: WebPanelView(
                      key: _panel,
                      policy: WebPanelPolicy.fromUrl(config.baseUrl),
                      sourceIdentity: sessionGeneration,
                      sourceCurrent: () => isHaSessionCurrent(lease),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
