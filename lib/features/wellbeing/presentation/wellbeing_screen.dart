import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/settings_section.dart';
import '../data/wellbeing_controller.dart';
import '../data/wellbeing_store.dart';
import '../data/wellbeing_disclosure_policy.dart';
import '../domain/wellbeing_models.dart';
import '../providers/wellbeing_providers.dart';

String wellbeingMetricLabel(AppLocalizations l10n, WellbeingMetric metric) =>
    switch (metric) {
      WellbeingMetric.bodyMass => l10n.wellbeingBodyMass,
      WellbeingMetric.bodyFatPercentage => l10n.wellbeingBodyFat,
      WellbeingMetric.steps => l10n.wellbeingSteps,
    };
String wellbeingSourceLabel(WellbeingSource source) => switch (source) {
  WellbeingSource.homeAssistant => 'Home Assistant',
  WellbeingSource.healthConnect => 'Health Connect',
  WellbeingSource.healthKit => 'Apple Health',
  WellbeingSource.huaweiHealth => 'Huawei Health',
};
String wellbeingStatusLabel(
  AppLocalizations l10n,
  WellbeingProviderStatus status,
) => switch (status.availability) {
  WellbeingAvailability.available => l10n.wellbeingAvailable,
  WellbeingAvailability.unsupportedPlatform => l10n.wellbeingUnsupported,
  WellbeingAvailability.unavailableOnDevice => l10n.wellbeingUnavailable,
  WellbeingAvailability.installOrUpdateRequired => l10n.wellbeingInstall,
  WellbeingAvailability.providerRegistrationRequired =>
    l10n.wellbeingRegistration,
  WellbeingAvailability.integrationPending => l10n.wellbeingPending,
  WellbeingAvailability.notConfigured => l10n.wellbeingNotConfigured,
};
String wellbeingPermissionLabel(
  AppLocalizations l10n,
  WellbeingPermission permission,
) => switch (permission) {
  WellbeingPermission.granted => l10n.wellbeingPermissionGranted,
  WellbeingPermission.denied => l10n.wellbeingPermissionDenied,
  WellbeingPermission.notRequested => l10n.wellbeingPermissionNotRequested,
  WellbeingPermission.unknown => l10n.wellbeingPermissionUnknown,
};

class WellbeingScreen extends ConsumerStatefulWidget {
  const WellbeingScreen({
    super.key,
    required this.onLock,
    required this.onExit,
  });
  final VoidCallback onLock;
  final VoidCallback onExit;
  @override
  ConsumerState<WellbeingScreen> createState() => _WellbeingScreenState();
}

class _WellbeingScreenState extends ConsumerState<WellbeingScreen> {
  final _profile = TextEditingController();
  Set<WellbeingMetric> _metrics = {};
  WellbeingSettings? _loaded;
  WellbeingController? _controller;
  bool _saving = false;
  bool _dialogOpen = false;
  bool _candidatesRequested = false;
  bool? _showSources;
  String? _error;

  bool get _active =>
      mounted &&
      TickerMode.valuesOf(context).enabled &&
      ref.read(wellbeingAccessProvider)?.isCurrent() == true;
  bool get _canAct =>
      _active &&
      ModalRoute.of(context)?.isCurrent == true &&
      !_saving &&
      !_dialogOpen;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!TickerMode.valuesOf(context).enabled) _controller?.setVisible(false);
  }

  @override
  void dispose() {
    _controller?.setVisible(false);
    _profile.dispose();
    super.dispose();
  }

  Future<T?> _dialog<T>(Future<T?> Function() open) async {
    if (!_canAct) return null;
    setState(() => _dialogOpen = true);
    try {
      return await open();
    } finally {
      if (mounted) setState(() => _dialogOpen = false);
    }
  }

  Future<void> _reloadSettings(WellbeingAccessSession captured) async {
    bool current() =>
        _active &&
        ModalRoute.of(context)?.isCurrent == true &&
        identical(captured, ref.read(wellbeingAccessProvider)) &&
        captured.isCurrent();
    if (!_canAct || !current()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      ref.invalidate(wellbeingSettingsProvider);
      ref.invalidate(wellbeingDisclosureProvider);
      // Local configuration only. Native and HA reads remain explicit actions.
      await Future.wait([
        ref.read(wellbeingSettingsProvider.future),
        ref.read(wellbeingDisclosureProvider.future),
      ]);
    } catch (_) {
      if (current()) {
        setState(
          () =>
              _error = AppLocalizations.of(context)
                  .wellbeingSettingsUnavailable,
        );
      }
    } finally {
      if (current()) setState(() => _saving = false);
    }
  }

  Future<void> _save(WellbeingSettings value) async {
    if (!_canAct) return;
    final access = ref.read(wellbeingAccessProvider);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(wellbeingSettingsProvider.notifier)
          .save(value, isCurrent: () => mounted && access?.isCurrent() == true);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = AppLocalizations.of(context).wellbeingSaveFailed,
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _permissionSettings() async {
    if (!_canAct) return;
    try {
      await ref.read(wellbeingNativeApiProvider).openPermissionSettings();
    } catch (_) {
      if (mounted && _active) {
        setState(
          () => _error = AppLocalizations.of(context).wellbeingReadFailed,
        );
      }
    }
  }

  Future<void> _changeDisclosure(
    WellbeingDisclosurePolicy policy, {
    String? entityId,
  }) async {
    if (!_canAct) return;
    final access = ref.read(wellbeingAccessProvider);
    final l10n = AppLocalizations.of(context);
    final accepted = await _dialog<bool>(
      () => showCupertinoDialog<bool>(
        context: context,
        useRootNavigator: false,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: Text(entityId ?? l10n.wellbeingReviewPrivacy),
          content: Text(
            entityId == null
                ? l10n.wellbeingPrivacyReviewConfirm
                : l10n.wellbeingDisclosureConfirm,
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => _closeDialog(dialogContext, false),
              child: Text(l10n.commonCancel),
            ),
            CupertinoDialogAction(
              onPressed: () => _closeDialog(dialogContext, true),
              child: Text(l10n.commonOk),
            ),
          ],
        ),
      ),
    );
    if (accepted != true || !_canAct || access?.isCurrent() != true) return;
    final current = ref.read(wellbeingDisclosureProvider);
    if (current.isLoading ||
        current.hasError ||
        !identical(current.value, policy)) {
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(wellbeingDisclosureProvider.notifier)
          .save(
            WellbeingDisclosurePolicy(
              entityIds: policy.entityIds.where((id) => id != entityId).toSet(),
              reviewRequired: entityId == null ? false : policy.reviewRequired,
            ),
            isCurrent: () => mounted && access?.isCurrent() == true,
          );
    } catch (_) {
      if (mounted) setState(() => _error = l10n.wellbeingSaveFailed);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _bind(HaWellbeingCandidate candidate) async {
    if (!_canAct) return;
    final l10n = AppLocalizations.of(context);
    if (!validWellbeingLabel(_profile.text.trim())) {
      setState(() => _error = l10n.wellbeingNeedsProfile);
      return;
    }
    final controller = _controller;
    final access = ref.read(wellbeingAccessProvider);
    final metric = await _dialog<WellbeingMetric>(
      () => showCupertinoModalPopup<WellbeingMetric>(
        context: context,
        useRootNavigator: false,
        builder: (sheetContext) => CupertinoActionSheet(
          title: Text(candidate.name),
          message: Text(l10n.wellbeingScaleHint),
          actions: [
            for (final metric in candidate.compatibleMetrics)
              CupertinoActionSheetAction(
                onPressed: () => _closeDialog(sheetContext, metric),
                child: Text(wellbeingMetricLabel(l10n, metric)),
              ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => _closeDialog<WellbeingMetric>(sheetContext, null),
            child: Text(l10n.commonCancel),
          ),
        ),
      ),
    );
    if (metric == null ||
        !_canAct ||
        access?.isCurrent() != true ||
        !identical(controller, _controller)) {
      return;
    }
    final settings = ref.read(wellbeingSettingsProvider);
    if (settings.isLoading || settings.hasError || settings.value == null) {
      return;
    }
    try {
      final binding = controller!.bindCandidate(
        candidate,
        metric,
        _profile.text.trim(),
      );
      final saved = settings.value!;
      await _save(
        WellbeingSettings(
          enabled: saved.enabled,
          profileLabel: _profile.text.trim(),
          nativeMetrics: saved.nativeMetrics,
          bindings: [
            ...saved.bindings.where(
              (old) =>
                  old.entityId != binding.entityId ||
                  old.accountFingerprint != binding.accountFingerprint,
            ),
            binding,
          ],
        ),
      );
    } catch (_) {
      if (mounted) setState(() => _error = l10n.wellbeingSaveFailed);
    }
  }

  Future<void> _remove(
    HaWellbeingBinding binding,
    WellbeingSettings settings,
  ) async {
    if (!_canAct) return;
    final l10n = AppLocalizations.of(context);
    final access = ref.read(wellbeingAccessProvider);
    final accepted = await _dialog<bool>(
      () => showCupertinoDialog<bool>(
        context: context,
        useRootNavigator: false,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: Text(l10n.wellbeingRemove),
          content: Text(l10n.wellbeingLocalOnly),
          actions: [
            CupertinoDialogAction(
              onPressed: () => _closeDialog(dialogContext, false),
              child: Text(l10n.commonCancel),
            ),
            CupertinoDialogAction(
              isDestructiveAction: true,
              onPressed: () => _closeDialog(dialogContext, true),
              child: Text(l10n.wellbeingRemove),
            ),
          ],
        ),
      ),
    );
    if (accepted != true || !_canAct || access?.isCurrent() != true) return;
    final latest = ref.read(wellbeingSettingsProvider);
    if (latest.isLoading ||
        latest.hasError ||
        !identical(settings, latest.value)) {
      return;
    }
    await _save(
      WellbeingSettings(
        enabled: settings.enabled,
        profileLabel: settings.profileLabel,
        nativeMetrics: settings.nativeMetrics,
        bindings: settings.bindings.where((v) => v.id != binding.id).toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final access = ref.watch(wellbeingAccessProvider);
    if (access?.isCurrent() != true) {
      return AppPageScaffold(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(l10n.wellbeingPinRequired),
          ),
        ),
      );
    }
    final stored = ref.watch(wellbeingSettingsProvider);
    final disclosure = ref.watch(wellbeingDisclosureProvider);
    final settings = stored.isLoading || stored.hasError ? null : stored.value;
    if (settings != null && !identical(settings, _loaded)) {
      _loaded = settings;
      _candidatesRequested = false;
      _profile.text = settings.profileLabel;
      _metrics = Set.of(settings.nativeMetrics);
    }
    _controller = ref.watch(wellbeingControllerProvider);
    _controller?.setVisible(_active);
    final reading = ref.watch(wellbeingProvider);
    final snapshot = !_active || reading.isLoading || reading.hasError
        ? null
        : reading.value;
    final busy = _saving || snapshot?.busy == true;
    final nativeAvailable =
        snapshot
            ?.statuses[ref.watch(wellbeingNativeApiProvider).source]
            ?.availability ==
        WellbeingAvailability.available;
    final ready = settings != null && _canAct && !busy;
    final showSources =
        _showSources ??
        !(settings?.enabled == true &&
            (settings!.nativeMetrics.isNotEmpty ||
                settings.bindings.isNotEmpty));
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        leading: CupertinoNavigationBarBackButton(onPressed: widget.onExit),
        middle: Text(l10n.wellbeingTitle),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: widget.onLock,
          child: Semantics(
            label: l10n.wellbeingLock,
            child: const Icon(CupertinoIcons.lock),
          ),
        ),
      ),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: CustomScrollView(
              key: PageStorageKey('wellbeing-$showSources'),
              slivers: [
                SliverToBoxAdapter(
                  child: Column(
                    children: [
                      _WellbeingText(l10n.wellbeingPrivacy),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        child: SizedBox(
                          width: double.infinity,
                          child: CupertinoSlidingSegmentedControl<bool>(
                            groupValue: showSources,
                            onValueChanged: (value) {
                              if (_canAct && value != null) {
                                setState(() => _showSources = value);
                              }
                            },
                            children: {
                              false: Padding(
                                padding: const EdgeInsets.all(10),
                                child: Text(l10n.wellbeingReadingsTab),
                              ),
                              true: Padding(
                                padding: const EdgeInsets.all(10),
                                child: Text(l10n.wellbeingSourcesTab),
                              ),
                            },
                          ),
                        ),
                      ),
                      if (stored.isLoading || busy)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: CupertinoActivityIndicator(),
                        ),
                      if (stored.hasError || disclosure.hasError) ...[
                        _WellbeingText(l10n.wellbeingSettingsUnavailable),
                        CupertinoButton(
                          key: const Key('wellbeing-reload'),
                          onPressed: _canAct && !busy
                              ? () => _reloadSettings(access!)
                              : null,
                          child: Text(l10n.wellbeingReloadSettings),
                        ),
                      ],
                      if (reading.hasError || snapshot?.failure != null)
                        _WellbeingText(l10n.wellbeingReadFailed),
                      if (_error != null) _WellbeingText(_error!),
                      if (showSources && disclosure.isLoading)
                        _WellbeingText(l10n.wellbeingReadFailed),
                      if (showSources &&
                          !disclosure.isLoading &&
                          !disclosure.hasError &&
                          disclosure.hasValue &&
                          (disclosure.requireValue.reviewRequired ||
                              disclosure.requireValue.entityIds.isNotEmpty))
                        SettingsSection(
                          header: Text(l10n.wellbeingSharedPrivacy),
                          footer: Text(l10n.wellbeingDisclosureHint),
                          children: [
                            if (disclosure.requireValue.reviewRequired) ...[
                              _WellbeingText(l10n.wellbeingPrivacyReviewHint),
                              CupertinoButton(
                                onPressed: ready
                                    ? () => _changeDisclosure(
                                        disclosure.requireValue,
                                      )
                                    : null,
                                child: Text(l10n.wellbeingReviewPrivacy),
                              ),
                            ],
                            for (final id in disclosure.requireValue.entityIds)
                              Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(id),
                                    CupertinoButton(
                                      onPressed: ready
                                          ? () => _changeDisclosure(
                                              disclosure.requireValue,
                                              entityId: id,
                                            )
                                          : null,
                                      child: Text(
                                        l10n.wellbeingRemoveRestriction,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      if (settings != null && showSources) ...[
                        SettingsSection(
                          footer: Text(l10n.wellbeingEnableHint),
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(16),
                              child: Row(
                                children: [
                                  Expanded(child: Text(l10n.wellbeingEnable)),
                                  const SizedBox(width: 12),
                                  CupertinoSwitch(
                                    value: settings.enabled,
                                    onChanged: ready
                                        ? (enabled) => _save(
                                            WellbeingSettings(
                                              enabled: enabled,
                                              profileLabel:
                                                  settings.profileLabel,
                                              nativeMetrics:
                                                  settings.nativeMetrics,
                                              bindings: settings.bindings,
                                            ),
                                          )
                                        : null,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 8,
                          ),
                          child: CupertinoTextField(
                            key: const ValueKey('wellbeing-profile'),
                            controller: _profile,
                            enabled: ready && settings.enabled,
                            maxLength: 80,
                            placeholder: l10n.wellbeingProfile,
                            padding: const EdgeInsets.all(14),
                          ),
                        ),
                        SettingsSection(
                          header: Text(l10n.wellbeingSources),
                          children: [
                            CupertinoButton(
                              onPressed: ready
                                  ? () => _controller?.probe()
                                  : null,
                              child: Text(l10n.wellbeingProbe),
                            ),
                            for (final status
                                in snapshot?.statuses.values ??
                                    <WellbeingProviderStatus>[])
                              Padding(
                                padding: const EdgeInsets.all(16),
                                child: SizedBox(
                                  width: double.infinity,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        wellbeingSourceLabel(status.source),
                                        style: AppText.headline,
                                      ),
                                      Text(wellbeingStatusLabel(l10n, status)),
                                      for (final entry
                                          in status.permissions.entries)
                                        Text(
                                          '${wellbeingMetricLabel(l10n, entry.key)}: ${wellbeingPermissionLabel(l10n, entry.value)}',
                                          style: AppText.footnote,
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                        if (settings.enabled) ...[
                          SettingsSection(
                            header: Text(l10n.wellbeingNative),
                            footer: Text(l10n.wellbeingNativeHint),
                            children: [
                              for (final metric in WellbeingMetric.values)
                                Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          wellbeingMetricLabel(l10n, metric),
                                        ),
                                      ),
                                      CupertinoSwitch(
                                        value: _metrics.contains(metric),
                                        onChanged: ready
                                            ? (value) => setState(() {
                                                if (value) {
                                                  _metrics.add(metric);
                                                } else {
                                                  _metrics.remove(metric);
                                                }
                                              })
                                            : null,
                                      ),
                                    ],
                                  ),
                                ),
                              CupertinoButton(
                                onPressed: ready
                                    ? () {
                                        if (!validWellbeingLabel(
                                          _profile.text.trim(),
                                        )) {
                                          setState(
                                            () => _error =
                                                l10n.wellbeingNeedsProfile,
                                          );
                                          return;
                                        }
                                        _save(
                                          WellbeingSettings(
                                            enabled: settings.enabled,
                                            profileLabel: _profile.text.trim(),
                                            nativeMetrics: _metrics,
                                            bindings: settings.bindings,
                                          ),
                                        );
                                      }
                                    : null,
                                child: Text(l10n.wellbeingSaveTypes),
                              ),
                              CupertinoButton(
                                onPressed:
                                    ready &&
                                        nativeAvailable &&
                                        settings.nativeMetrics.isNotEmpty
                                    ? () =>
                                          _controller?.requestNativePermissions(
                                            settings.nativeMetrics,
                                          )
                                    : null,
                                child: Text(l10n.wellbeingGrant),
                              ),
                              CupertinoButton(
                                onPressed: ready && nativeAvailable
                                    ? _permissionSettings
                                    : null,
                                child: Text(l10n.wellbeingManagePermissions),
                              ),
                            ],
                          ),
                          SettingsSection(
                            header: Text(l10n.wellbeingScale),
                            footer: Text(l10n.wellbeingScaleHint),
                            children: [
                              CupertinoButton(
                                onPressed: ready
                                    ? () {
                                        setState(
                                          () => _candidatesRequested = true,
                                        );
                                        _controller?.loadHaCandidates();
                                      }
                                    : null,
                                child: Text(l10n.wellbeingChooseScale),
                              ),
                              for (final binding in settings.bindings)
                                Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${binding.profileLabel} · ${wellbeingMetricLabel(l10n, binding.metric)}',
                                        style: AppText.headline,
                                      ),
                                      Text(
                                        binding.entityId,
                                        style: AppText.footnote,
                                      ),
                                      CupertinoButton(
                                        padding: EdgeInsets.zero,
                                        onPressed: ready
                                            ? () => _remove(binding, settings)
                                            : null,
                                        child: Text(l10n.wellbeingRemove),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
                if (showSources &&
                    settings?.enabled == true &&
                    snapshot != null)
                  SliverList.builder(
                    itemCount: snapshot.haCandidates.length,
                    itemBuilder: (_, index) {
                      final candidate = snapshot.haCandidates[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: CupertinoButton(
                          alignment: Alignment.centerLeft,
                          onPressed: ready ? () => _bind(candidate) : null,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(candidate.name),
                              Text(
                                '${candidate.entityId} · ${candidate.unit}',
                                style: AppText.footnote,
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                if (showSources && settings?.enabled == true) ...[
                  if (_candidatesRequested &&
                      !busy &&
                      snapshot?.haCandidates.isEmpty == true)
                    SliverToBoxAdapter(
                      child: _WellbeingText(l10n.wellbeingNoScaleCandidates),
                    ),
                ],
                if (!showSources && settings?.enabled != true)
                  SliverToBoxAdapter(
                    child: _WellbeingText(l10n.wellbeingEnableHint),
                  ),
                if (!showSources && settings?.enabled == true) ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: CupertinoButton.filled(
                        onPressed:
                            ready &&
                                (settings.nativeMetrics.isNotEmpty ||
                                    settings.bindings.isNotEmpty)
                            ? () => _controller?.refresh()
                            : null,
                        child: Text(l10n.wellbeingRead),
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: _WellbeingText(l10n.wellbeingRecent),
                  ),
                  if (snapshot?.results.isEmpty != false)
                    SliverToBoxAdapter(
                      child: _WellbeingText(l10n.wellbeingNoRead),
                    ),
                  for (final result
                      in snapshot?.results ?? <WellbeingReadResult>[]) ...[
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${wellbeingSourceLabel(result.source)} · ${wellbeingMetricLabel(l10n, result.metric)}',
                              style: AppText.title3,
                            ),
                            if (result.state != WellbeingReadState.data)
                              Text(switch (result.state) {
                                WellbeingReadState.empty => l10n.wellbeingEmpty,
                                WellbeingReadState.emptyOrNotShared =>
                                  l10n.wellbeingEmptyOrPrivate,
                                WellbeingReadState.failed =>
                                  l10n.wellbeingReadFailed,
                                _ => l10n.wellbeingNoRead,
                              }),
                            if (result.truncated) Text(l10n.wellbeingTruncated),
                          ],
                        ),
                      ),
                    ),
                    SliverList.builder(
                      itemCount: result.measurements.length,
                      itemBuilder: (_, index) =>
                          _MeasurementCard(result.measurements[index]),
                    ),
                  ],
                ],
                const SliverToBoxAdapter(child: SizedBox(height: 24)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

void _closeDialog<T>(BuildContext context, T? value) {
  if (context.mounted && ModalRoute.of(context)?.isCurrent == true) {
    Navigator.of(context).pop(value);
  }
}

class _WellbeingText extends StatelessWidget {
  const _WellbeingText(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    child: SizedBox(
      width: double.infinity,
      child: Text(text, style: AppText.subhead),
    ),
  );
}

class _MeasurementCard extends StatelessWidget {
  const _MeasurementCard(this.measurement);
  final WellbeingMeasurement measurement;
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final time = DateFormat.yMd(l10n.localeName).add_Hm();
    String format(DateTime value) => time.format(value.toLocal());
    return SettingsSection(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(measurement.profileLabel, style: AppText.headline),
                Text(
                  '${NumberFormat('0.##', l10n.localeName).format(measurement.value)} ${measurement.metric == WellbeingMetric.steps ? l10n.wellbeingStepUnit : measurement.unit}',
                  style: AppText.title1,
                ),
                if (measurement.measuredAt != null)
                  Text(
                    '${measurement.intervalEnd != null ? l10n.wellbeingIntervalStart : l10n.wellbeingMeasuredAt}: ${format(measurement.measuredAt!)}',
                  )
                else
                  Text(l10n.wellbeingTimeUnknown),
                if (measurement.intervalEnd != null)
                  Text(
                    '${l10n.wellbeingIntervalEnd}: ${format(measurement.intervalEnd!)}',
                  ),
                if (measurement.sourceUpdatedAt != null)
                  Text(
                    '${l10n.wellbeingUpdatedAt}: ${format(measurement.sourceUpdatedAt!)}',
                    style: AppText.footnote,
                  ),
                Text(
                  '${l10n.wellbeingReadAt}: ${format(measurement.readAt)}',
                  style: AppText.footnote,
                ),
                if (measurement.originName != null)
                  Text(measurement.originName!, style: AppText.footnote),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
