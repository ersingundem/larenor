import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/action_status_indicator.dart';
import '../../auth/providers/auth_providers.dart';
import '../data/today_timezone.dart';
import '../domain/today_models.dart';
import '../providers/today_providers.dart';

/// Invalidates in-flight UI work and drafts across accounts or app backgrounding.
/// The provider owns network lifecycle; widgets never start polling in build.
abstract class TodayConsumerState<T extends ConsumerStatefulWidget>
    extends ConsumerState<T> {
  late final AppLifecycleListener _lifecycle;
  int generation = 0;
  bool foreground = true;
  TodaySnapshot? _blockedSnapshot;
  AppInteractionController? _interaction;
  int _interactionEpoch = 0;
  bool get interactionActive => _interaction?.active ?? true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = AppInteractionScope.maybeOf(context);
    if (identical(next, _interaction)) return;
    final hadScope = _interaction != null;
    _interaction?.removeListener(_interactionChanged);
    _interaction = next;
    _interactionEpoch = next?.epoch ?? 0;
    next?.addListener(_interactionChanged);
    if (hadScope || !interactionActive) {
      generation++;
      clearSession();
    }
  }

  void _interactionChanged() {
    if (!mounted) return;
    final epoch = _interaction?.epoch ?? 0;
    if (epoch != _interactionEpoch) {
      _interactionEpoch = epoch;
      generation++;
      clearSession();
    }
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    foreground = state == null || state == AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        // Redact while frames are still enabled, before an app-switch snapshot.
        if (state != AppLifecycleState.resumed) {
          if (!foreground) return;
          setState(() {
            foreground = false;
            generation++;
            clearSession();
          });
        } else if (state == AppLifecycleState.resumed && !foreground) {
          setState(() => foreground = true);
        }
      },
    );
  }

  void clearSession() {}

  TodaySnapshot? watchSnapshot() {
    final connection = ref.watch(connectionConfigProvider);
    ref.listen(connectionConfigProvider, (previous, next) {
      if (previous == null || previous == next) return;
      _blockedSnapshot = ref.exists(todayProvider)
          ? ref.read(todayProvider).value
          : null;
      setState(() {
        generation++;
        clearSession();
      });
    });
    if (!interactionActive) return null;
    final state = ref.watch(todayProvider);
    if (!foreground ||
        !interactionActive ||
        connection.isLoading ||
        connection.hasError ||
        state.isLoading ||
        state.hasError ||
        identical(state.value, _blockedSnapshot)) {
      return null;
    }
    return state.value;
  }

  TodaySnapshot? readSnapshot() {
    if (!interactionActive) return null;
    final connection = ref.read(connectionConfigProvider);
    final state = ref.read(todayProvider);
    if (!foreground ||
        connection.isLoading ||
        connection.hasError ||
        state.isLoading ||
        state.hasError ||
        identical(state.value, _blockedSnapshot)) {
      return null;
    }
    return state.value;
  }

  VoidCallback guarded(VoidCallback operation) {
    final epoch = generation;
    return () {
      if (isCurrent(epoch)) operation();
    };
  }

  bool isCurrent(int epoch) =>
      mounted && foreground && interactionActive && generation == epoch;

  @override
  void dispose() {
    generation++;
    _interaction?.removeListener(_interactionChanged);
    _lifecycle.dispose();
    super.dispose();
  }
}

TodayTodoList? findTodayList(TodaySnapshot? snapshot, String id) {
  for (final list in snapshot?.todoLists ?? const <TodayTodoList>[]) {
    if (list.entityId == id) return list;
  }
  return null;
}

TodayTodoItem? findTodayItem(TodayTodoList? list, String? uid) {
  if (uid == null) return null;
  for (final item in list?.items.value ?? const <TodayTodoItem>[]) {
    if (item.uid == uid) return item;
  }
  return null;
}

bool todayListWritable(TodaySnapshot snapshot, TodayTodoList list) =>
    snapshot.configured &&
    list.available &&
    list.items.value != null &&
    list.items.issue == null &&
    !snapshot.issues.any(
      (issue) =>
          issue.source == TodaySource.configuration ||
          (issue.source == TodaySource.todos &&
              (issue.entityId == null || issue.entityId == list.entityId)),
    );

String todayFailureLabel(AppLocalizations l10n, TodayFailure failure) =>
    switch (failure) {
      TodayFailure.authentication => l10n.healthAuthenticationRequired,
      TodayFailure.permission => l10n.healthPermissionDenied,
      TodayFailure.unsupported => l10n.todayUnsupported,
      TodayFailure.unavailable => l10n.todayUnavailable,
      _ => l10n.todayReadError,
    };

String todayActionError(AppLocalizations l10n, Object error) =>
    error is TodayException
    ? (error.code == 'missing_item' || error.code == 'missing_uid'
          ? l10n.todayMissingItem
          : l10n.todayInvalidOperation)
    : actionErrorLabel(l10n, error);

String todayDate(BuildContext context, DateTime value) =>
    DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag())
        .format(value);
String todayTime(BuildContext context, DateTime value) =>
    DateFormat.Hm(Localizations.localeOf(context).toLanguageTag())
        .format(value);

String todayTimestamp(BuildContext context, DateTime value, String? zone) {
  var local = value.toUtc();
  var suffix = ' UTC';
  if (zone != null) {
    try {
      local = TodayTimeZone(zone).local(value);
      suffix = '';
    } on TodayException {
      /* Unknown zone is displayed explicitly as UTC. */
    }
  }
  return '${todayDate(context, local)} · ${todayTime(context, local)}$suffix';
}

String todayEventTime(BuildContext context, TodayCalendarEvent event) {
  final l10n = AppLocalizations.of(context);
  if (event.allDay) {
    // Date-only math deliberately avoids the device timezone and DST days.
    final start = parseDateOnly(event.startDate!);
    final exclusive = parseDateOnly(event.endDate!);
    final last = DateTime.utc(
      exclusive.year,
      exclusive.month,
      exclusive.day - 1,
    );
    final dates =
        start.year == last.year &&
            start.month == last.month &&
            start.day == last.day
        ? todayDate(context, start)
        : '${todayDate(context, start)} – ${todayDate(context, last)}';
    return '${l10n.todayAllDay} · $dates';
  }
  return '${todayDate(context, event.start)} · ${todayTime(context, event.start)}'
      ' – ${todayDate(context, event.end)} · ${todayTime(context, event.end)}';
}

class TodayCard extends StatelessWidget {
  const TodayCard({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
        context,
      ),
      borderRadius: BorderRadius.circular(18),
    ),
    child: child,
  );
}

class TodayReadNotice<T> extends StatelessWidget {
  const TodayReadNotice({
    super.key,
    required this.read,
    required this.timeZone,
  });
  final TodayRead<T> read;
  final String? timeZone;
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (read.issue != null)
          Text(
            todayFailureLabel(l10n, read.issue!.failure),
            style: AppText.footnote,
          ),
        if (read.isStale) Text(l10n.todayStale, style: AppText.footnote),
        if (read.value == null && read.issue == null)
          Text(l10n.todayUnread, style: AppText.footnote),
        if (read.readAt != null && (read.isStale || read.value == null))
          Text(
            l10n.todayRefreshed(
              todayTimestamp(context, read.readAt!, timeZone),
            ),
            style: AppText.caption1,
          ),
      ],
    );
  }
}
