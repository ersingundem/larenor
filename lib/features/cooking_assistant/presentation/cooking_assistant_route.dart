import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../core/home_session_controller.dart';
import '../../../core/home_source_store.dart';
import '../data/cooking_session_api.dart';
import '../data/cooking_session_controller.dart';
import '../data/cooking_timer_notifications.dart';
import '../data/cooking_timers_controller.dart';
import '../data/cooking_timers_storage.dart';
import '../domain/cooking_session.dart';
import '../domain/cooking_timer.dart';
import 'cooking_assistant_workspace_screen.dart';
import 'cooking_session_screen.dart';
import 'cooking_timers_screen.dart';

final class CookingAssistantRoute extends ConsumerStatefulWidget {
  const CookingAssistantRoute({super.key});

  @override
  ConsumerState<CookingAssistantRoute> createState() =>
      _CookingAssistantRouteState();
}

final class _CookingAssistantRouteState
    extends ConsumerState<CookingAssistantRoute> {
  HomeSessionController? _home;
  AppInteractionController? _interaction;
  Object? _identity;
  int? _generation, _homeEpoch;
  int _operation = 0;
  CookingSessionAccountApi? _api;
  CookingSessionController? _sessionController;
  CookingTimersController? _timersController;
  List<CookingSession> _sessions = const [];
  bool _loading = false;
  bool _failed = false;

  bool _bindingCurrent() {
    final home = _home;
    return mounted &&
        home != null &&
        identical(ref.read(homeSessionControllerProvider), home) &&
        identical(home.runtimeIdentity, _identity) &&
        home.account.generation == _generation &&
        home.interaction.epoch == _homeEpoch;
  }

  bool _authorityCurrent() {
    if (!_bindingCurrent()) return false;
    final home = _home!;
    final session = home.account.session;
    return (_interaction?.active ?? true) &&
        home.source == HomeSource.verifiedCore &&
        !home.busy &&
        home.failure == null &&
        home.interaction.active &&
        session?.context != null &&
        session!.user.mustChangePassword == false;
  }

  bool _current() =>
      _authorityCurrent() &&
      TickerMode.valuesOf(context).enabled &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  void _changed() {
    if (!mounted) return;
    if (!_authorityCurrent()) {
      _retire(clearSessions: true);
    } else if (_api == null && !_loading) {
      unawaited(_load());
    }
    setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final home = ref.read(homeSessionControllerProvider);
    final interaction = AppInteractionScope.maybeOf(context);
    if (_home == null && home != null) {
      _home = home;
      _identity = home.runtimeIdentity;
      _generation = home.account.generation;
      _homeEpoch = home.interaction.epoch;
      home.addListener(_changed);
    }
    if (!identical(_interaction, interaction)) {
      _interaction?.removeListener(_changed);
      _interaction = interaction;
      interaction?.addListener(_changed);
    }
    if (_api == null && !_loading && _authorityCurrent()) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    if (!_authorityCurrent() || _loading) return;
    final operation = ++_operation;
    _loading = true;
    _failed = false;
    if (mounted) setState(() {});
    final api =
        _api ??
        CookingSessionAccountApi(account: _home!.account, isCurrent: _current);
    _api = api;
    try {
      final sessions = await api.list();
      if (operation != _operation || !_current()) return;
      final accountId = _home!.account.session!.user.id;
      if (sessions.any((session) => session.accountId != accountId)) {
        throw const FormatException('cooking_session_account_mismatch');
      }
      _sessions = sessions;
      _failed = false;
    } catch (_) {
      if (operation == _operation) _failed = true;
    } finally {
      if (operation == _operation) _loading = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _create(_CookingStrings strings) async {
    if (!_current()) return;
    final title = TextEditingController();
    final steps = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(strings.create),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: title,
                maxLength: 200,
                autofocus: true,
                decoration: InputDecoration(labelText: strings.recipeTitle),
              ),
              TextField(
                controller: steps,
                minLines: 4,
                maxLines: 10,
                maxLength: 12000,
                decoration: InputDecoration(
                  labelText: strings.steps,
                  helperText: strings.oneStepPerLine,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(strings.start),
          ),
        ],
      ),
    );
    final normalizedTitle = title.text.trim();
    final normalizedSteps = steps.text
        .split('\n')
        .map((step) => step.trim())
        .where((step) => step.isNotEmpty)
        .toList(growable: false);
    title.dispose();
    steps.dispose();
    if (accepted != true ||
        normalizedTitle.isEmpty ||
        normalizedSteps.isEmpty ||
        normalizedSteps.length > 100 ||
        normalizedSteps.any((step) => step.length > 2000) ||
        !_current()) {
      return;
    }
    setState(() => _loading = true);
    try {
      final created = await _api!.create(
        recipeId: 'manual-${DateTime.now().toUtc().microsecondsSinceEpoch}',
        recipeRevision: 1,
        title: normalizedTitle,
        steps: normalizedSteps,
      );
      if (!_current()) return;
      _sessions = [created, ..._sessions];
      _open(created);
    } catch (_) {
      if (_authorityCurrent()) _failed = true;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _open(CookingSession session) {
    if (!_current()) return;
    _disposeWorkspace();
    final accountId = _home!.account.session!.user.id;
    if (session.accountId != accountId) {
      setState(() => _failed = true);
      return;
    }
    _sessionController = CookingSessionController(
      gateway: _api!,
      initial: session,
      isCurrent: _current,
    );
    _timersController = CookingTimersController(
      store: SharedPreferencesCookingTimerStore(),
      notifications: DurableCookingTimerNotifications(),
      clock: SystemCookingTimerClock(),
      authority: CookingTimerAuthority(
        accountId: accountId,
        recipeSessionId: session.id,
        epoch: _operation,
      ),
      isCurrent: _current,
    );
    unawaited(_timersController!.restore());
    setState(() {});
  }

  void _disposeWorkspace() {
    _sessionController?.dispose();
    _timersController?.dispose();
    _sessionController = null;
    _timersController = null;
  }

  void _retire({required bool clearSessions}) {
    _operation++;
    _disposeWorkspace();
    _api?.close();
    _api = null;
    _loading = false;
    if (clearSessions) _sessions = const [];
  }

  @override
  void dispose() {
    _interaction?.removeListener(_changed);
    _home?.removeListener(_changed);
    _retire(clearSessions: true);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(homeSessionControllerProvider);
    final strings = _CookingStrings.of(context);
    final sessionController = _sessionController;
    final timersController = _timersController;
    if (sessionController != null && timersController != null && _current()) {
      final tr = Localizations.localeOf(context).languageCode == 'tr';
      return Scaffold(
        appBar: AppBar(
          leading: BackButton(
            onPressed: () {
              _disposeWorkspace();
              unawaited(_load());
              setState(() {});
            },
          ),
          title: Text(sessionController.value.title),
        ),
        body: CookingAssistantWorkspaceScreen(
          sessionController: sessionController,
          timersController: timersController,
          workspaceStrings: tr
              ? CookingWorkspaceStrings.tr
              : CookingWorkspaceStrings.en,
          sessionStrings: tr
              ? CookingAssistantStrings.tr
              : CookingAssistantStrings.en,
          timerStrings: tr ? CookingTimerStrings.tr : CookingTimerStrings.en,
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(strings.title),
        actions: [
          IconButton(
            tooltip: strings.refresh,
            onPressed: !_current() || _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: !_current() || _loading || _api == null
            ? null
            : () => _create(strings),
        icon: const Icon(Icons.add),
        label: Text(strings.create),
      ),
      body: SafeArea(
        child: _loading && _sessions.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : !_authorityCurrent()
            ? Center(child: Text(strings.unavailable))
            : _failed && _sessions.isEmpty
            ? Center(
                child: FilledButton.icon(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh),
                  label: Text(strings.retry),
                ),
              )
            : _sessions.isEmpty
            ? Center(child: Text(strings.empty))
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                  itemCount: _sessions.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final session = _sessions[index];
                    return ListTile(
                      enabled: !session.cancelled && _current(),
                      leading: Icon(
                        session.cancelled
                            ? Icons.check_circle_outline
                            : Icons.restaurant_menu,
                      ),
                      title: Text(session.title),
                      subtitle: Text(
                        session.cancelled
                            ? strings.ended
                            : strings.progress(
                                session.currentStep + 1,
                                session.steps.length,
                              ),
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _open(session),
                    );
                  },
                ),
              ),
      ),
    );
  }
}

@immutable
final class _CookingStrings {
  const _CookingStrings({
    required this.title,
    required this.create,
    required this.recipeTitle,
    required this.steps,
    required this.oneStepPerLine,
    required this.start,
    required this.cancel,
    required this.empty,
    required this.unavailable,
    required this.retry,
    required this.refresh,
    required this.ended,
    required this.step,
  });

  static const en = _CookingStrings(
    title: 'Cooking assistant',
    create: 'New cooking session',
    recipeTitle: 'Recipe title',
    steps: 'Recipe steps',
    oneStepPerLine: 'Enter one step per line.',
    start: 'Start cooking',
    cancel: 'Cancel',
    empty: 'No cooking session yet. Start one from a recipe.',
    unavailable: 'Cooking assistant is unavailable for this account.',
    retry: 'Try again',
    refresh: 'Refresh sessions',
    ended: 'Ended',
    step: 'Step',
  );
  static const tr = _CookingStrings(
    title: 'Pişirme asistanı',
    create: 'Yeni pişirme oturumu',
    recipeTitle: 'Tarif adı',
    steps: 'Tarif adımları',
    oneStepPerLine: 'Her satıra bir adım girin.',
    start: 'Pişirmeyi başlat',
    cancel: 'Vazgeç',
    empty: 'Henüz pişirme oturumu yok. Bir tarifle başlayın.',
    unavailable: 'Pişirme asistanı bu hesap için kullanılamıyor.',
    retry: 'Tekrar dene',
    refresh: 'Oturumları yenile',
    ended: 'Bitti',
    step: 'Adım',
  );

  final String title;
  final String create;
  final String recipeTitle;
  final String steps;
  final String oneStepPerLine;
  final String start;
  final String cancel;
  final String empty;
  final String unavailable;
  final String retry;
  final String refresh;
  final String ended;
  final String step;

  static _CookingStrings of(BuildContext context) =>
      Localizations.localeOf(context).languageCode == 'tr' ? tr : en;
  String progress(int current, int total) => '$step $current / $total';
}
