import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/app_colors.dart';
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
    final generation = sessionGeneration;
    final consumed = await (_panel.currentState?.back() ?? Future.value(false));
    if (!mounted ||
        consumed ||
        route?.isCurrent != true ||
        !sessionCurrent(generation)) {
      return;
    }
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
      navigationBar: _HaFrontendNavigationBar(
        title: Text(l10n.haFrontend),
        leading: CupertinoButton(
          key: const ValueKey('ha-frontend-back'),
          minimumSize: const Size(48, 48),
          padding: EdgeInsets.zero,
          onPressed: _back,
          child: Icon(CupertinoIcons.back, semanticLabel: l10n.commonBack),
        ),
        trailing: CupertinoButton(
          key: const ValueKey('ha-frontend-retry'),
          minimumSize: const Size(48, 48),
          padding: EdgeInsets.zero,
          onPressed: lease == null
              ? null
              : () {
                  if (isHaSessionCurrent(lease)) _panel.currentState?.restart();
                },
          child: Icon(CupertinoIcons.refresh, semanticLabel: l10n.commonRetry),
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

class _HaFrontendNavigationBar extends StatelessWidget
    implements ObstructingPreferredSizeWidget {
  const _HaFrontendNavigationBar({
    required this.title,
    required this.leading,
    required this.trailing,
  });

  final Widget title;
  final Widget leading;
  final Widget trailing;

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  bool shouldFullyObstruct(BuildContext context) => true;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: AppColors.navigation.resolveFrom(context),
      border: Border(
        bottom: BorderSide(
          color: CupertinoColors.separator.resolveFrom(context),
          width: .5,
        ),
      ),
    ),
    child: SafeArea(
      bottom: false,
      child: SizedBox(
        height: 56,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              leading,
              const SizedBox(width: 8),
              Expanded(
                child: Center(
                  child: DefaultTextStyle(
                    style: CupertinoTheme.of(context)
                        .textTheme
                        .navTitleTextStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    child: title,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              trailing,
            ],
          ),
        ),
      ),
    ),
  );
}
