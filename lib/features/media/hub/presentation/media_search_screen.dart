import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../../../shared/widgets/app_page_scaffold.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../domain/media_title.dart';
import '../domain/media_read_result.dart';
import 'widgets/media_read_issue_banner.dart';
import '../providers/media_catalog_providers.dart';
import 'media_hub_screen.dart';
import 'widgets/media_poster.dart';
import 'widgets/media_theme.dart';

/// Searches the library and the requestable catalogue at once, so one
/// title is one result whether you already have it or not.
class MediaSearchScreen extends ConsumerStatefulWidget {
  const MediaSearchScreen({super.key});

  @override
  ConsumerState<MediaSearchScreen> createState() => _MediaSearchScreenState();
}

class _MediaSearchScreenState extends ConsumerState<MediaSearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// Debounced so typing doesn't fire a search per keystroke against two
  /// servers at once.
  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _query = value.trim());
    });
  }

  @override
  Widget build(BuildContext context) => MediaTheme(builder: _build);

  Widget _build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.mediaSearchTitle),
        previousPageTitle: l10n.mediaHubTitle,
      ),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: CupertinoSearchTextField(
                controller: _controller,
                autofocus: true,
                placeholder: l10n.mediaSearchPlaceholder,
                onChanged: _onChanged,
                onSubmitted: (value) {
                  _debounce?.cancel();
                  setState(() => _query = value.trim());
                },
              ),
            ),
            Expanded(child: _results(context, l10n)),
          ],
        ),
      ),
    );
  }

  Widget _results(BuildContext context, AppLocalizations l10n) {
    if (_query.isEmpty) return _Hint(text: l10n.mediaSearchPrompt);

    final resultsAsync = ref.watch(mediaSearchProvider(_query));

    return resultsAsync.when(
      skipLoadingOnRefresh: false,
      skipLoadingOnReload: false,
      loading: () => const Center(child: CupertinoActivityIndicator()),
      error: (error, _) => _Hint(text: l10n.healthReadError),
      data: (titles) {
        if (titles.isEmpty && titles.readIssues.isEmpty) {
          return _Hint(text: l10n.mediaSearchEmpty);
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final columns = ((constraints.maxWidth - 32) / 152).floor().clamp(
              2,
              12,
            );
            final width =
                (constraints.maxWidth - 32 - (columns - 1) * 12) / columns;
            return CustomScrollView(
              slivers: [
                if (titles.readIssues.isNotEmpty)
                  SliverToBoxAdapter(
                    child: MediaReadIssueBanner(
                      issues: titles.readIssues,
                      hasContent: titles.isNotEmpty,
                      onRetry: () {
                        ref.invalidate(mediaLibraryIndexProvider);
                        ref.invalidate(mediaSearchProvider(_query));
                      },
                    ),
                  ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      mainAxisSpacing: 14,
                      crossAxisSpacing: 12,
                      mainAxisExtent: MediaPoster.heightFor(width, context),
                    ),
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final title = titles[index];
                      return MediaPoster(
                        title: title,
                        width: double.infinity,
                        onTap: () {
                          if (!mounted) return;
                          final current = ref.read(mediaSearchProvider(_query));
                          if (current.isLoading ||
                              current.hasError ||
                              !identical(current.value, titles)) {
                            return;
                          }
                          openMediaTitle(context, title);
                        },
                      );
                    }, childCount: titles.length),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: CupertinoColors.secondaryLabel.resolveFrom(context),
        ),
      ),
    ),
  );
}

/// Exposed for tests: the widget renders [MediaTitle]s through
/// [MediaPoster], so this is the shape a result grid expects.
typedef MediaSearchResults = List<MediaTitle>;
