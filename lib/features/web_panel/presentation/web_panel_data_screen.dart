import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/app_interaction_scope.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/app_page_scaffold.dart';
import '../../dashboard/presentation/dashboard_edit_guard.dart';
import '../../settings/presentation/settings_file_dialog.dart';
import '../../settings/providers/settings_providers.dart';
import '../data/web_panel_data.dart';

/// Only linked from SettingsGate. Fresh PIN verification is also required here;
/// a source card must never offer a global destructive site-data operation.
class WebPanelDataScreen extends ConsumerStatefulWidget {
  const WebPanelDataScreen({super.key, this.coordinator});
  final WebPanelDataCoordinator? coordinator;
  @override
  ConsumerState<WebPanelDataScreen> createState() => _WebPanelDataState();
}

class _WebPanelDataState extends DashboardEditState<WebPanelDataScreen> {
  bool _busy = false, _expired = false, _clearing = false;
  String? _message;
  Route<bool>? _dialog;
  bool? _wasVisible, _wasCurrent;
  WebPanelDataCoordinator get _coordinator =>
      widget.coordinator ?? WebPanelDataCoordinator.shared;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    final current = ModalRoute.isCurrentOf(context) ?? true;
    if ((_wasVisible == true && !visible) ||
        (_wasCurrent == true && !current && _dialog == null)) {
      interactionGeneration++;
      invalidateDashboardInteraction();
    }
    _wasVisible = visible;
    _wasCurrent = current;
  }

  @override
  void invalidateDashboardInteraction() {
    _expired = true;
    _message = null;
    final route = _dialog;
    _dialog = null;
    if (route?.isActive == true) route!.navigator?.removeRoute(route);
  }

  bool _valid(int generation) =>
      mounted &&
      !_expired &&
      foreground &&
      generation == interactionGeneration &&
      AppInteractionScope.maybeRead(context)?.active != false &&
      TickerMode.valuesOf(context).enabled;

  Future<void> _clear() async {
    final generation = interactionGeneration;
    if (_busy || !_valid(generation) || !interactionCurrent(generation)) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    final l10n = AppLocalizations.of(context);
    try {
      final store = ref.read(pinLockStoreProvider);
      final originalPin = await store.read();
      if (!mounted || !_valid(generation) || !interactionCurrent(generation)) {
        return;
      }
      if (originalPin == null) {
        setState(() => _message = l10n.settingsSetPin);
        return;
      }
      final authorized = await reauthenticateSettingsFileDialog(
        context,
        store,
        onRoute: (route) => _dialog = route,
      );
      final pinRoute = _dialog;
      if (pinRoute is TransitionRoute<bool>) await pinRoute.completed;
      _dialog = null;
      if (!mounted ||
          !authorized ||
          !_valid(generation) ||
          !interactionCurrent(generation)) {
        return;
      }
      var accepted = false;
      final route = CupertinoDialogRoute<bool>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: Text(l10n.webPanelDataConfirm),
          content: Text(l10n.webPanelDataWarning),
          actions: [
            CupertinoDialogAction(
              onPressed: () => closeDashboardModal(dialogContext, false),
              child: Text(l10n.commonCancel),
            ),
            CupertinoDialogAction(
              key: const ValueKey('web-data-confirm'),
              isDestructiveAction: true,
              onPressed: () {
                if (accepted ||
                    !_valid(generation) ||
                    ModalRoute.of(dialogContext)?.isCurrent != true) {
                  return;
                }
                accepted = true;
                closeDashboardModal(dialogContext, true);
              },
              child: Text(l10n.webPanelDataClear),
            ),
          ],
        ),
      );
      _dialog = route;
      final confirmed = await Navigator.of(context).push(route);
      await route.completed;
      if (identical(_dialog, route)) _dialog = null;
      if (confirmed != true ||
          !_valid(generation) ||
          !interactionCurrent(generation)) {
        return;
      }
      final latestPin = await store.read();
      if (!_valid(generation) ||
          !interactionCurrent(generation) ||
          latestPin != originalPin) {
        return;
      }
      setState(() => _clearing = true);
      final success = await _coordinator.clear(
        isCurrent: () => _valid(generation) && interactionCurrent(generation),
      );
      if (_valid(generation)) {
        setState(
          () => _message = success
              ? l10n.webPanelDataDone
              : l10n.webPanelDataFailed,
        );
      }
    } catch (_) {
      if (_valid(generation)) {
        setState(() => _message = l10n.webPanelDataFailed);
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _clearing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    watchDashboardAccount();
    final pin = ref.watch(pinLockProvider);
    ref.listen(pinLockProvider, (previous, next) {
      if (previous?.hasValue == true &&
          (next.isLoading || next.hasError || previous?.value != next.value)) {
        setState(() {
          interactionGeneration++;
          invalidateDashboardInteraction();
        });
      }
    });
    final l10n = AppLocalizations.of(context);
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.webPanelDataTitle),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(l10n.webPanelDataWarning),
            const SizedBox(height: 20),
            if (_expired)
              Text(l10n.dashboardWidgetPickerExpired)
            else if (pin.isLoading)
              const Center(child: CupertinoActivityIndicator())
            else if (pin.hasError)
              Text(l10n.settingsGateStorageError)
            else if (pin.value == null)
              Text(l10n.settingsSetPin)
            else
              CupertinoButton(
                key: const ValueKey('web-data-clear'),
                onPressed: _busy ? null : _clear,
                child: _clearing
                    ? const CupertinoActivityIndicator()
                    : Text(
                        l10n.webPanelDataClear,
                        style: TextStyle(
                          color: CupertinoColors.systemRed.resolveFrom(context),
                        ),
                      ),
              ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(top: 20),
                child: Text(_message!),
              ),
          ],
        ),
      ),
    );
  }
}
