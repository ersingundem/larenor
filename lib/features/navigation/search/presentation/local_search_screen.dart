import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/app_interaction_scope.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/spacing.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/app_page_scaffold.dart';
import '../../../media/hub/presentation/media_search_screen.dart';
import '../domain/local_search_index.dart';
import '../domain/navigation_target.dart';
import '../providers/local_search_providers.dart';

class LocalSearchScreen extends ConsumerStatefulWidget {
  const LocalSearchScreen({
    super.key,
    required this.onOpenTarget,
    this.onOpenRemoteMedia,
    this.autofocus = false,
  });
  final ValueChanged<NavigationTarget> onOpenTarget;
  final VoidCallback? onOpenRemoteMedia;
  final bool autofocus;

  @override
  ConsumerState<LocalSearchScreen> createState() => _LocalSearchScreenState();
}

class _LocalSearchScreenState extends ConsumerState<LocalSearchScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode(debugLabel: 'Local search');
  late final AppLifecycleListener _lifecycle;
  bool _foreground = true;
  Timer? _debounce;
  String _query = '';
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        _foreground = state == AppLifecycleState.resumed;
        if (!_foreground) _focus.unfocus();
      },
    );
    if (widget.autofocus) _scheduleFocus();
    // Re-entering from a media tab can expose a newly loaded passive cache.
    Future.microtask(() {
      if (mounted) {
        ref.read(localSearchIndexProvider.notifier).refreshCachedSources();
      }
    });
  }

  @override
  void didUpdateWidget(covariant LocalSearchScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.autofocus && !oldWidget.autofocus) _scheduleFocus();
  }

  bool get _canFocus =>
      mounted &&
      _foreground &&
      (AppInteractionScope.maybeRead(context)?.active ?? true) &&
      TickerMode.valuesOf(context).enabled &&
      ModalRoute.of(context)?.isCurrent == true;

  void _scheduleFocus() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_canFocus) _focus.requestFocus();
  });

  void _focusSearch() {
    if (_canFocus) _focus.requestFocus();
  }

  void _closeSearch() {
    if (_canFocus) Navigator.of(context).maybePop();
  }

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    _lifecycle.dispose();
    super.dispose();
  }

  void _commit(String value, int generation) {
    if (!mounted || generation != _generation) return;
    ref.read(localSearchIndexProvider.notifier).refreshCachedSources();
    setState(() => _query = value.trim());
  }

  void _changed(String value) {
    final generation = ++_generation;
    _debounce?.cancel();
    if (value.trim().isEmpty) {
      _commit(value, generation);
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 150),
      () => _commit(value, generation),
    );
  }

  void _submitted(String value) {
    _debounce?.cancel();
    _commit(value, ++_generation);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    final index = ref.watch(localSearchIndexProvider);
    final results = ref.watch(localSearchResultsProvider(_query));
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(
          LogicalKeyboardKey.keyK,
          control: true,
          includeRepeats: false,
        ): _focusSearch,
        const SingleActivator(LogicalKeyboardKey.escape, includeRepeats: false):
            _closeSearch,
      },
      child: FocusScope(
        autofocus: true,
        child: AppPageScaffold(
          navigationBar: CupertinoNavigationBar(
            middle: Text(l10n.navigationSearchTitle),
          ),
          child: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 960),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: CupertinoSearchTextField(
                        controller: _controller,
                        focusNode: _focus,
                        placeholder: l10n.navigationSearchHint,
                        onChanged: _changed,
                        onSubmitted: _submitted,
                        autofocus: false,
                      ),
                    ),
                    if (!keyboardVisible)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            l10n.navigationSearchLocalHint,
                            style: AppText.footnote.copyWith(
                              color: CupertinoColors.secondaryLabel.resolveFrom(
                                context,
                              ),
                            ),
                          ),
                        ),
                      ),
                    Expanded(
                      child: results.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Text(
                                  index.isEmpty
                                      ? l10n.navigationSearchNoCache
                                      : _query.isEmpty
                                      ? l10n.navigationSearchHint
                                      : l10n.navigationSearchEmpty,
                                  textAlign: TextAlign.center,
                                  style: AppText.subhead.copyWith(
                                    color: CupertinoColors.secondaryLabel
                                        .resolveFrom(context),
                                  ),
                                ),
                              ),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              keyboardDismissBehavior:
                                  ScrollViewKeyboardDismissBehavior.onDrag,
                              itemCount: results.length,
                              itemBuilder: (context, item) => _SearchResultRow(
                                key: ValueKey(results[item].id),
                                item: results[item],
                                onTap: () =>
                                    widget.onOpenTarget(results[item].target),
                              ),
                            ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: CupertinoButton(
                        padding: keyboardVisible
                            ? const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 6,
                              )
                            : null,
                        onPressed:
                            widget.onOpenRemoteMedia ??
                            () => Navigator.of(context).push(
                              CupertinoPageRoute<void>(
                                builder: (_) => const MediaSearchScreen(),
                              ),
                            ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(CupertinoIcons.globe, size: 20),
                            const SizedBox(width: Gap.sm),
                            Flexible(
                              child: Text(
                                l10n.navigationSearchRemote,
                                style: keyboardVisible
                                    ? AppText.footnote
                                    : null,
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchResultRow extends StatelessWidget {
  const _SearchResultRow({super.key, required this.item, required this.onTap});
  final LocalSearchItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final (icon, kindLabel) = switch (item.kind) {
      LocalSearchKind.room => (CupertinoIcons.house, l10n.navigationSearchRoom),
      LocalSearchKind.entity => (
        CupertinoIcons.square_grid_2x2,
        l10n.navigationSearchEntity,
      ),
      LocalSearchKind.scene => (
        CupertinoIcons.sparkles,
        l10n.navigationSearchScene,
      ),
      LocalSearchKind.script => (
        CupertinoIcons.doc_text,
        l10n.navigationSearchScript,
      ),
      LocalSearchKind.media => (
        CupertinoIcons.play_rectangle,
        l10n.homeCategoryMedia,
      ),
      LocalSearchKind.system => (
        CupertinoIcons.square_stack_3d_up,
        l10n.navigationSearchSystem,
      ),
      LocalSearchKind.page => switch (item.target) {
        HomePageNavigationTarget(page: HomePageTarget.today) => (
          CupertinoIcons.calendar,
          l10n.navigationSearchPage,
        ),
        HomePageNavigationTarget(page: HomePageTarget.energy) => (
          CupertinoIcons.bolt_fill,
          l10n.navigationSearchPage,
        ),
        HomePageNavigationTarget(page: HomePageTarget.intercom) => (
          CupertinoIcons.bell,
          l10n.navigationSearchPage,
        ),
        MediaPageNavigationTarget(page: MediaPageTarget.sources) => (
          CupertinoIcons.tv,
          l10n.navigationSearchPage,
        ),
        _ => (CupertinoIcons.music_note_2, l10n.navigationSearchPage),
      },
    };
    final title = switch (item.target) {
      HomePageNavigationTarget(page: HomePageTarget.today) => l10n.todayTitle,
      HomePageNavigationTarget(page: HomePageTarget.energy) => l10n.energyTitle,
      HomePageNavigationTarget(page: HomePageTarget.intercom) =>
        l10n.intercomTitle,
      MediaPageNavigationTarget(page: MediaPageTarget.music) => l10n.musicTitle,
      MediaPageNavigationTarget(page: MediaPageTarget.sources) =>
        l10n.haMediaTitle,
      MediaPageNavigationTarget(page: MediaPageTarget.audio) =>
        l10n.localAudioTitle,
      _ => item.title,
    };
    final details = [
      kindLabel,
      ...item.roomNames,
      if (item.detail != null) item.detail!,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
          context,
        ),
        borderRadius: BorderRadius.circular(16),
        onPressed: onTap,
        child: Row(
          children: [
            Icon(icon, size: 24),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppText.body.copyWith(
                      color: CupertinoColors.label.resolveFrom(context),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    details,
                    style: AppText.footnote.copyWith(
                      color: CupertinoColors.secondaryLabel.resolveFrom(
                        context,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(CupertinoIcons.chevron_forward, size: 16),
          ],
        ),
      ),
    );
  }
}
