import 'package:flutter/cupertino.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/app_page_scaffold.dart';

class CoreHaButton extends StatelessWidget {
  const CoreHaButton({super.key, required this.label, required this.onPressed, this.selected, required this.isCurrent});
  final String label;
  final VoidCallback? onPressed;
  final bool? selected;
  final bool Function() isCurrent;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(4),
    child: Builder(builder: (padded) => Focus(
      canRequestFocus: false, skipTraversal: true,
      onFocusChange: (focused) {
        if (!focused) return;
        final node = FocusManager.instance.primaryFocus;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!padded.mounted || node?.hasFocus != true || !isCurrent() || !TickerMode.valuesOf(padded).enabled || ModalRoute.of(padded)?.isCurrent != true) return;
          Scrollable.ensureVisible(padded, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
        });
      },
      child: Semantics(selected: selected, child: CupertinoButton(
        minimumSize: const Size(48, 48), padding: const EdgeInsets.all(14),
        focusColor: CupertinoTheme.of(context).primaryColor,
        onPressed: onPressed,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (selected == true) ...[const ExcludeSemantics(child: Icon(CupertinoIcons.checkmark, size: 22)), const SizedBox(width: 8)],
          Flexible(child: Text(label, textAlign: TextAlign.center)),
        ]),
      )),
    )),
  );
}

class CoreHaPage extends StatelessWidget {
  const CoreHaPage({super.key, required this.title, required this.slivers, required this.onBack, this.backKey = 'core-ha-back'});
  final String title, backKey;
  final List<Widget> slivers;
  final VoidCallback? onBack;
  @override
  Widget build(BuildContext context) => AppPageScaffold(child: SafeArea(child: Column(children: [
    Row(children: [
      CoreHaButton(key: ValueKey(backKey), label: AppLocalizations.of(context).commonBack, onPressed: onBack, isCurrent: () => onBack != null),
      Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(0, 12, 16, 12), child: Semantics(container: true, header: true, child: Text(title, style: CupertinoTheme.of(context).textTheme.navTitleTextStyle)))),
    ]),
    Expanded(child: Align(alignment: Alignment.topCenter, child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 880), child: CustomScrollView(key: const ValueKey('core-ha-scroll'), slivers: slivers)))),
  ])));
}
Widget coreHaBlock(List<Widget> children) => SliverPadding(padding: const EdgeInsets.all(16), sliver: SliverToBoxAdapter(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children)));
