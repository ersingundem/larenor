import 'package:flutter/cupertino.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/app_page_scaffold.dart';

class PeopleButton extends StatelessWidget {
  const PeopleButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.semanticLabel,
    this.selected,
    this.destructive = false,
  });
  final String label;
  final String? semanticLabel;
  final VoidCallback? onPressed;
  final bool? selected;
  final bool destructive;
  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onFocusChange: (focused) {
      if (focused && context.mounted) {
        Scrollable.ensureVisible(
          context,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        );
      }
    },
    child: Semantics(
      selected: selected,
      child: CupertinoButton(
        minimumSize: const Size(48, 48),
        focusColor: CupertinoTheme.of(context).primaryColor,
        padding: const EdgeInsets.all(14),
        onPressed: onPressed,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected == true) ...[
              const ExcludeSemantics(
                child: Icon(CupertinoIcons.checkmark, size: 22),
              ),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                label,
                semanticsLabel: semanticLabel,
                textAlign: TextAlign.center,
                style: destructive
                    ? TextStyle(
                        color: CupertinoColors.systemRed.resolveFrom(context),
                      )
                    : null,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class PeoplePage extends StatelessWidget {
  const PeoplePage({
    super.key,
    required this.title,
    required this.slivers,
    required this.onBack,
    this.backKey = 'home-people-back',
  });
  final String title, backKey;
  final List<Widget> slivers;
  final VoidCallback? onBack;
  @override
  Widget build(BuildContext context) => AppPageScaffold(
    child: SafeArea(
      child: Column(
        children: [
          Row(
            children: [
              Padding(
                padding: const EdgeInsets.all(4),
                child: PeopleButton(
                  key: ValueKey(backKey),
                  label: AppLocalizations.of(context).commonBack,
                  onPressed: onBack,
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 12, 16, 12),
                  child: Semantics(
                    header: true,
                    child: Text(
                      title,
                      style: CupertinoTheme.of(context)
                          .textTheme
                          .navTitleTextStyle,
                    ),
                  ),
                ),
              ),
            ],
          ),
          Expanded(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 880),
                child: CustomScrollView(slivers: slivers),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

Widget peopleBlock(List<Widget> children) => SliverPadding(
  padding: const EdgeInsets.all(20),
  sliver: SliverToBoxAdapter(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  ),
);
Widget peopleMessage(String key, String message) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 12),
  child: Semantics(liveRegion: true, child: Text(message, key: ValueKey(key))),
);
