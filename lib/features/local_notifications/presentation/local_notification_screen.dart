import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../core/window/window_policy_providers.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../data/local_notification_runtime.dart';
import '../domain/local_notification_models.dart';
import 'local_notification_platform_card.dart';
import 'local_notification_runtime_scope.dart';

class LocalNotificationScreen extends ConsumerStatefulWidget {
  const LocalNotificationScreen({super.key});
  @override
  ConsumerState<LocalNotificationScreen> createState() =>
      _LocalNotificationScreenState();
}

class _LocalNotificationScreenState
    extends ConsumerState<LocalNotificationScreen> {
  LocalNotificationRuntimeCoordinator? _runtime;

  bool _windowCurrent() {
    final state = ref.read(windowPolicySnapshotProvider);
    return !state.isLoading &&
        !state.hasError &&
        state.hasValue &&
        (!state.requireValue.supported ||
            state.requireValue.isResumed &&
                state.requireValue.hasWindowFocus &&
                !state.requireValue.isPictureInPicture);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final runtime = LocalNotificationRuntimeScope.of(context);
    if (identical(runtime, _runtime)) return;
    _runtime?.removeListener(_changed);
    _runtime = runtime..addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _runtime?.removeListener(_changed);
    super.dispose();
  }

  bool _routeCurrent() {
    final interaction = AppInteractionScope.maybeRead(context);
    return mounted &&
        _windowCurrent() &&
        (interaction?.active ?? true) &&
        TickerMode.valuesOf(context).enabled &&
        ModalRoute.of(context)?.isCurrent == true;
  }

  Future<void> _detail(LocalNotificationEvent event) async {
    final controller = _runtime!.controller;
    if (!_routeCurrent() ||
        !identical(
          controller.events.where((item) => identical(item, event)).firstOrNull,
          event,
        )) {
      return;
    }
    final route = LocalNotificationRoutePolicy.allowed(event.target);
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (sheetContext) {
        final l10n = AppLocalizations.of(sheetContext);
        return CupertinoPopupSurface(
          child: SafeArea(
            top: false,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(event.title, style: AppText.title2),
                    ),
                    const SizedBox(height: 12),
                    Text(event.body, style: AppText.body),
                    const SizedBox(height: 20),
                    CupertinoButton.filled(
                      key: const ValueKey('notification-read-action'),
                      minimumSize: const Size(48, 48),
                      onPressed: () async {
                        bool current() =>
                            mounted &&
                            _routeCurrent() &&
                            ModalRoute.of(sheetContext)?.isCurrent == true;
                        final accepted = await controller.markRead(
                          event,
                          interactionCurrent: current,
                        );
                        if (!accepted || !current() || !sheetContext.mounted) {
                          return;
                        }
                        Navigator.of(sheetContext).pop();
                        if (route != null && mounted && _routeCurrent()) {
                          context.go(route);
                        }
                      },
                      child: Text(
                        route == null
                            ? l10n.localNotificationsMarkRead
                            : l10n.localNotificationsOpen,
                      ),
                    ),
                    CupertinoButton(
                      minimumSize: const Size(48, 48),
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      child: Text(l10n.commonCancel),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(windowPolicySnapshotProvider);
    final l10n = AppLocalizations.of(context), runtime = _runtime;
    final controller = runtime?.controller;
    return AppPageScaffold(
      child: SafeArea(
        child: CustomScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            CupertinoSliverNavigationBar(
              largeTitle: Text(l10n.localNotificationsTitle),
              trailing: CupertinoButton(
                key: const ValueKey('notification-refresh'),
                minimumSize: const Size(48, 48),
                padding: EdgeInsets.zero,
                onPressed: controller?.canRefresh == true
                    ? controller!.refresh
                    : null,
                child: Semantics(
                  label: l10n.commonRefresh,
                  child: const ExcludeSemantics(
                    child: Icon(CupertinoIcons.refresh),
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  LocalNotificationPrivacyBanner(
                    permission:
                        controller?.permission ??
                        LocalNotificationPermission.denied,
                  ),
                  const SizedBox(height: 16),
                  if (runtime != null) ...[
                    LocalNotificationPlatformCard(
                      status: runtime.platformStatus,
                      onRequestPermission:
                          runtime.platformBusy || !_routeCurrent()
                          ? null
                          : () => runtime.requestPermission(
                              interactionCurrent: _routeCurrent,
                            ),
                      onOpenNotificationSettings:
                          runtime.platformBusy || !_routeCurrent()
                          ? null
                          : () => runtime.openNotificationSettings(
                              current: _routeCurrent,
                            ),
                      onOpenPowerSettings:
                          runtime.platformBusy || !_routeCurrent()
                          ? null
                          : () => runtime.openPowerSettings(
                              current: _routeCurrent,
                            ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (controller == null ||
                      controller.busy && !controller.loaded)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(32),
                        child: CupertinoActivityIndicator(),
                      ),
                    )
                  else if (controller.failure != null)
                    _Message(
                      key: const ValueKey('notification-error'),
                      text: l10n.localNotificationsError,
                      action: controller.canRefresh ? controller.refresh : null,
                      actionLabel: l10n.commonRetry,
                    )
                  else if (!controller.loaded || controller.events.isEmpty)
                    _Message(
                      key: const ValueKey('notification-empty'),
                      text: l10n.localNotificationsEmpty,
                      action: controller.canRefresh ? controller.refresh : null,
                      actionLabel: l10n.commonRefresh,
                    )
                  else
                    LocalNotificationPreviewGrid(
                      events: controller.events,
                      enabled: !controller.busy,
                      onOpen: _detail,
                    ),
                  if (controller?.canLoadMore == true)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: CupertinoButton(
                        key: const ValueKey('notification-load-more'),
                        minimumSize: const Size(48, 48),
                        onPressed: controller!.loadMore,
                        child: Text(l10n.localNotificationsLoadMore),
                      ),
                    ),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class LocalNotificationPreviewGrid extends StatelessWidget {
  const LocalNotificationPreviewGrid({
    super.key,
    required this.events,
    required this.enabled,
    required this.onOpen,
  });
  final List<LocalNotificationEvent> events;
  final bool enabled;
  final ValueChanged<LocalNotificationEvent> onOpen;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 900 ? 2 : 1;
      return GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: 14,
          mainAxisSpacing: 14,
          mainAxisExtent: 176,
        ),
        itemCount: events.length,
        itemBuilder: (_, index) => LocalNotificationPreviewCard(
          event: events[index],
          onPressed: enabled ? () => onOpen(events[index]) : null,
        ),
      );
    },
  );
}

class LocalNotificationPrivacyBanner extends StatelessWidget {
  const LocalNotificationPrivacyBanner({super.key, required this.permission});
  final LocalNotificationPermission permission;
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Semantics(
      container: true,
      label: l10n.localNotificationsPrivacySemantics,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.surface.resolveFrom(context),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(CupertinoIcons.lock_shield, size: 26),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.localNotificationsPrivacyTitle,
                      style: AppText.headline,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.localNotificationsPrivacyBody,
                      style: AppText.subhead,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      permission == LocalNotificationPermission.systemAllowed
                          ? l10n.localNotificationsPermissionSystem
                          : l10n.localNotificationsPermissionInApp,
                      style: AppText.footnote,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class LocalNotificationPreviewCard extends StatelessWidget {
  const LocalNotificationPreviewCard({
    super.key,
    required this.event,
    required this.onPressed,
  });
  final LocalNotificationEvent event;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context), projection = event.projection;
    return Semantics(
      button: true,
      readOnly: event.readState == LocalNotificationReadState.read,
      label:
          '${projection.title}. ${projection.redacted ? l10n.localNotificationsPrivate : projection.body}',
      child: CupertinoButton(
        key: ValueKey('notification-${event.sequence}'),
        padding: EdgeInsets.zero,
        minimumSize: const Size(48, 48),
        onPressed: onPressed,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.surface.resolveFrom(context),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: event.readState == LocalNotificationReadState.unread
                  ? CupertinoColors.activeBlue.resolveFrom(context)
                  : CupertinoColors.separator.resolveFrom(context),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: SizedBox.expand(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        projection.redacted
                            ? CupertinoIcons.lock_fill
                            : CupertinoIcons.bell_fill,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          projection.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.headline,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: Text(
                      projection.redacted
                          ? l10n.localNotificationsPrivate
                          : projection.body,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.body,
                    ),
                  ),
                  Text(
                    event.readState == LocalNotificationReadState.read
                        ? l10n.localNotificationsRead
                        : l10n.localNotificationsUnread,
                    style: AppText.footnote,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    super.key,
    required this.text,
    required this.action,
    required this.actionLabel,
  });
  final String text, actionLabel;
  final VoidCallback? action;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          CupertinoButton(
            minimumSize: const Size(48, 48),
            onPressed: action,
            child: Text(actionLabel),
          ),
        ],
      ),
    ),
  );
}
