import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../settings/presentation/settings_file_dialog.dart';
import '../../settings/presentation/panes/settings_nav_row.dart';
import '../domain/ambient_settings.dart';
import '../providers/ambient_providers.dart';
import 'ambient_screen.dart';

class AmbientSettingsScreen extends ConsumerStatefulWidget {
  const AmbientSettingsScreen({super.key, this.runFileDialog});
  final SettingsFileDialogRunner? runFileDialog;

  @override
  ConsumerState<AmbientSettingsScreen> createState() =>
      _AmbientSettingsScreenState();
}

class _AmbientSettingsScreenState extends ConsumerState<AmbientSettingsScreen>
    with WidgetsBindingObserver {
  bool _busy = false, _foreground = true;
  String? _message;
  int _generation = 0;
  bool _wasVisible = true;
  bool _ownDialog = false;
  AppInteractionController? _interaction;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.of(context)?.isCurrent != false || _ownDialog);
    if (_wasVisible && !visible) _generation++;
    _wasVisible = visible;
    final interaction = AppInteractionScope.maybeOf(context);
    if (!identical(interaction, _interaction)) {
      _interaction?.removeListener(_interactionChanged);
      _interaction = interaction;
      _interaction?.addListener(_interactionChanged);
    }
  }

  void _interactionChanged() {
    if (_interaction?.active == false) _generation++;
  }

  bool get _current =>
      mounted &&
      _foreground &&
      _interaction?.active != false &&
      TickerMode.valuesOf(context).enabled &&
      ModalRoute.of(context)?.isCurrent != false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) _generation++;
  }

  @override
  void dispose() {
    _generation++;
    _interaction?.removeListener(_interactionChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _save(int generation, AmbientSettings value) async {
    if (!_current || _busy || generation != _generation) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await ref
          .read(ambientSettingsProvider.notifier)
          .set(value, isCurrent: () => _current && generation == _generation);
    } catch (error) {
      if (_current && generation == _generation) _error(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _error(Object error) {
    final l10n = AppLocalizations.of(context);
    setState(
      () => _message = error is AmbientException && error.limit
          ? l10n.ambientLimit
          : l10n.ambientFailed,
    );
  }

  Future<void> _pick(int generation) async {
    if (!_current || _busy || generation != _generation) return;
    final initialGeneration = _generation;
    final access = ref.read(ambientFileAccessProvider);
    final repository = ref.read(ambientRepositoryProvider);
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final runner = widget.runFileDialog;
      final bytes = runner == null
          ? await access.pickPhoto()
          : await runner(access.pickPhoto);
      if (!mounted || bytes == null) return;
      // The settings gate owns reauthentication after the native picker. Wait
      // until its protected nested route is visible before importing any bytes.
      await WidgetsBinding.instance.endOfFrame;
      if (!_current || (runner == null && initialGeneration != _generation)) {
        return;
      }
      final acceptedGeneration = _generation;
      await repository.importPhoto(
        bytes,
        isCurrent: () => _current && acceptedGeneration == _generation,
      );
      if (mounted) ref.invalidate(ambientLibraryProvider);
    } catch (error) {
      if (_current) _error(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reorder(
    int generation,
    List<String> expected,
    int index,
    int delta,
  ) async {
    if (generation != _generation ||
        !_current ||
        _busy ||
        index + delta < 0 ||
        index + delta >= expected.length) {
      return;
    }
    final next = List<String>.of(expected);
    next.insert(index + delta, next.removeAt(index));
    await _replace(expected, next);
  }

  Future<void> _replace(List<String> expected, List<String> next) async {
    if (!_current || _busy) return;
    final generation = _generation;
    final repository = ref.read(ambientRepositoryProvider);
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await repository.replaceOrder(
        next,
        expected: expected,
        isCurrent: () =>
            _current &&
            generation == _generation &&
            ref.read(ambientLibraryProvider).value?.join() == expected.join(),
      );
      if (mounted) ref.invalidate(ambientLibraryProvider);
    } catch (error) {
      if (_current && generation == _generation) _error(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(int generation, List<String> ids, int index) async {
    if (!_current || _busy || generation != _generation) return;
    final l10n = AppLocalizations.of(context);
    var confirmed = false;
    final route = CupertinoDialogRoute<void>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(l10n.ambientPhoto(index + 1)),
        content: Text(l10n.ambientRemoveMessage),
        actions: [
          CupertinoDialogAction(
            onPressed: () {
              if (dialogContext.mounted &&
                  ModalRoute.of(dialogContext)?.isCurrent == true) {
                Navigator.pop(dialogContext);
              }
            },
            child: Text(l10n.commonCancel),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () {
              if (!mounted ||
                  generation != _generation ||
                  !_foreground ||
                  _interaction?.active == false ||
                  !dialogContext.mounted ||
                  ModalRoute.of(dialogContext)?.isCurrent != true) {
                return;
              }
              confirmed = true;
              Navigator.pop(dialogContext);
            },
            child: Text(l10n.commonRemove),
          ),
        ],
      ),
    );
    _ownDialog = true;
    setState(() => _busy = true);
    await Navigator.of(context).push(route);
    await route.completed;
    _ownDialog = false;
    if (!mounted) return;
    setState(() => _busy = false);
    if (!confirmed || !_current || generation != _generation) return;
    await _replace(ids, List<String>.of(ids)..removeAt(index));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final settings = ref.watch(ambientSettingsProvider);
    final library = ref.watch(ambientLibraryProvider);
    final value = settings.isLoading || settings.hasError
        ? null
        : settings.value;
    final ids = library.isLoading || library.hasError ? null : library.value;
    final available = _current && !_busy;
    final generation = _generation;

    Widget toggle(
      String title,
      bool selected,
      ValueChanged<bool> action, {
      String? hint,
    }) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MergeSemantics(
            child: Row(
              children: [
                Expanded(child: Text(title)),
                const SizedBox(width: 12),
                CupertinoSwitch(
                  value: selected,
                  onChanged: available ? action : null,
                ),
              ],
            ),
          ),
          if (hint != null) ...[
            const SizedBox(height: 8),
            Text(
              hint,
              style: TextStyle(
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
                fontSize: 15,
              ),
            ),
          ],
        ],
      ),
    );

    return SettingsPaneScaffold(
      title: l10n.ambientTitle,
      children: [
        SettingsSection(
          footer: Text(l10n.ambientHint),
          children: [
            CupertinoButton(
              onPressed: available
                  ? () => Navigator.of(context).push(
                      CupertinoPageRoute<void>(
                        builder: (_) => CupertinoPageScaffold(
                          navigationBar: CupertinoNavigationBar(
                            middle: Text(l10n.ambientTitle),
                          ),
                          child: const SafeArea(child: AmbientScreen()),
                        ),
                      ),
                    )
                  : null,
              child: Text(l10n.ambientPreview),
            ),
          ],
        ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _message!,
              style: TextStyle(
                color: CupertinoColors.systemRed.resolveFrom(context),
              ),
            ),
          ),
        if (value == null)
          SettingsSection(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: settings.isLoading
                    ? const CupertinoActivityIndicator()
                    : Text(l10n.ambientFailed),
              ),
              if (settings.hasError)
                CupertinoButton(
                  onPressed: available
                      ? () => ref.invalidate(ambientSettingsProvider)
                      : null,
                  child: Text(l10n.commonRetry),
                ),
            ],
          )
        else ...[
          SettingsSection(
            footer: Text(l10n.ambientSharedHint),
            children: [
              toggle(
                l10n.ambientPhotosEnabled,
                value.photosEnabled,
                (v) => _save(generation, value.copyWith(photosEnabled: v)),
              ),
              toggle(
                l10n.ambientClock,
                value.showClock,
                (v) => _save(generation, value.copyWith(showClock: v)),
              ),
              toggle(
                l10n.ambientWeather,
                value.showWeather,
                (v) => _save(generation, value.copyWith(showWeather: v)),
              ),
              toggle(
                l10n.ambientShift,
                value.pixelShift,
                (v) => _save(generation, value.copyWith(pixelShift: v)),
                hint: l10n.ambientShiftHint,
              ),
            ],
          ),
          SettingsSection(
            header: Text(l10n.ambientInterval),
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final interval in AmbientSettings.intervals)
                      CupertinoButton.tinted(
                        onPressed: available
                            ? () => _save(
                                generation,
                                value.copyWith(intervalSeconds: interval),
                              )
                            : null,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (interval == value.intervalSeconds) ...[
                              const Icon(CupertinoIcons.check_mark, size: 16),
                              const SizedBox(width: 6),
                            ],
                            Flexible(
                              child: Text(l10n.ambientSeconds(interval)),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          SettingsSection(
            header: Text(l10n.ambientFit),
            children: [
              for (final fit in AmbientPhotoFit.values)
                CupertinoButton(
                  onPressed: available
                      ? () => _save(generation, value.copyWith(fit: fit))
                      : null,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          fit == AmbientPhotoFit.contain
                              ? l10n.ambientContain
                              : l10n.ambientCover,
                        ),
                      ),
                      if (value.fit == fit)
                        const Icon(CupertinoIcons.check_mark),
                    ],
                  ),
                ),
            ],
          ),
        ],
        SettingsSection(
          header: Text(l10n.ambientPhotos),
          footer: Text(l10n.ambientStorageHint),
          children: [
            if (_busy)
              const Padding(
                padding: EdgeInsets.all(16),
                child: CupertinoActivityIndicator(),
              ),
            CupertinoButton(
              onPressed: available && ids != null && ids.length < 24
                  ? () => _pick(generation)
                  : null,
              child: Text(l10n.ambientAdd),
            ),
            if (library.hasError)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Text(l10n.ambientFailed),
                    CupertinoButton(
                      onPressed: available
                          ? () => ref.invalidate(ambientLibraryProvider)
                          : null,
                      child: Text(l10n.commonRetry),
                    ),
                  ],
                ),
              ),
            if (ids?.isEmpty == true)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(l10n.ambientEmpty),
              ),
            if (ids != null)
              for (var i = 0; i < ids.length; i++)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.ambientPhoto(i + 1)),
                      const SizedBox(height: 8),
                      _Thumbnail(id: ids[i]),
                      Wrap(
                        spacing: 8,
                        children: [
                          CupertinoButton(
                            onPressed: available && i > 0
                                ? () => _reorder(generation, ids, i, -1)
                                : null,
                            child: Text(l10n.dashboardMoveUp),
                          ),
                          CupertinoButton(
                            onPressed: available && i < ids.length - 1
                                ? () => _reorder(generation, ids, i, 1)
                                : null,
                            child: Text(l10n.dashboardMoveDown),
                          ),
                          CupertinoButton(
                            key: ValueKey('ambient-remove-${ids[i]}'),
                            onPressed: available
                                ? () => _remove(generation, ids, i)
                                : null,
                            child: Text(l10n.commonRemove),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ],
    );
  }
}

class _Thumbnail extends ConsumerWidget {
  const _Thumbnail({required this.id});
  final String id;
  @override
  Widget build(BuildContext context, WidgetRef ref) => SizedBox(
    height: 100,
    child: ref
        .watch(ambientPhotoProvider(id))
        .when(
          data: (bytes) => Image.memory(
            bytes,
            cacheHeight: 160,
            fit: BoxFit.contain,
            excludeFromSemantics: true,
            errorBuilder: (_, _, _) => const Icon(CupertinoIcons.photo),
          ),
          error: (_, _) => const Icon(CupertinoIcons.photo),
          loading: () => const CupertinoActivityIndicator(),
        ),
  );
}
