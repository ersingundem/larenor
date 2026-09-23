import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/app_interaction_scope.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/service_root_scaffold.dart';
import '../../../../shared/widgets/settings_action_tile.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../../dashboard/domain/dashboard_website_url.dart';
import '../../dashboard/domain/tile_config.dart';
import '../../dashboard/presentation/dashboard_edit_guard.dart';
import '../../settings/providers/settings_providers.dart';
import '../domain/web_panel_options.dart';
import '../domain/web_panel_policy.dart';

/// Edits a portable local draft. No website renderer or API client is created.
class WebPanelSettingsScreen extends ConsumerStatefulWidget {
  const WebPanelSettingsScreen({super.key, required this.initialTile});
  final TileConfig initialTile;
  @override
  ConsumerState<WebPanelSettingsScreen> createState() =>
      _WebPanelSettingsState();
}

class _WebPanelSettingsState
    extends DashboardEditState<WebPanelSettingsScreen> {
  late final TextEditingController _url, _title;
  final _origin = TextEditingController();
  late List<String> _origins;
  late bool _zoom;
  late bool _uploads, _downloads, _externalActions;
  late int _textZoom;
  bool _expired = false, _returned = false;
  String? _error;
  Route<bool>? _dialog;
  bool? _wasVisible, _wasCurrent;

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
  void initState() {
    super.initState();
    final tile = widget.initialTile;
    _url = TextEditingController(text: tile.url ?? 'https://');
    _title = TextEditingController(text: tile.title ?? '');
    _origins = [...?tile.webPanel?.additionalOrigins];
    _zoom = tile.webPanel?.zoomEnabled ?? true;
    _textZoom = tile.webPanel?.textZoom ?? 100;
    _uploads = tile.webPanel?.allowUploads ?? false;
    _downloads = tile.webPanel?.allowDownloads ?? false;
    _externalActions = tile.webPanel?.allowExternalActions ?? false;
  }

  @override
  void invalidateDashboardInteraction() {
    _expired = true;
    _url.clear();
    _title.clear();
    _origin.clear();
    _error = null;
    final route = _dialog;
    _dialog = null;
    if (route?.isActive == true) route!.navigator?.removeRoute(route);
  }

  bool _valid(int generation) =>
      mounted &&
      foreground &&
      !_expired &&
      !_returned &&
      interactionGeneration == generation &&
      AppInteractionScope.maybeRead(context)?.active != false &&
      TickerMode.valuesOf(context).enabled;

  Future<void> _addOrigin(int generation) async {
    if (!_valid(generation) ||
        _dialog != null ||
        !interactionCurrent(generation)) {
      return;
    }
    final value = WebOrigin.parseExact(_origin.text);
    final l10n = AppLocalizations.of(context);
    if (value == null ||
        _origins.length >= 15 ||
        _origins.contains(value.displayName) ||
        value == WebOrigin.parse(_url.text)) {
      setState(() => _error = l10n.webPanelOriginInvalid);
      return;
    }
    var chosen = false;
    final route = CupertinoDialogRoute<bool>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(l10n.webPanelOriginConfirm),
        content: Text('${value.displayName}\n\n${l10n.webPanelOriginHint}'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => closeDashboardModal(dialogContext, false),
            child: Text(l10n.commonCancel),
          ),
          CupertinoDialogAction(
            key: const ValueKey('web-origin-confirm'),
            onPressed: () {
              if (chosen ||
                  !_valid(generation) ||
                  ModalRoute.of(dialogContext)?.isCurrent != true) {
                return;
              }
              chosen = true;
              closeDashboardModal(dialogContext, true);
            },
            child: Text(l10n.commonAdd),
          ),
        ],
      ),
    );
    _dialog = route;
    final approved = await Navigator.of(context).push(route);
    await route.completed;
    if (identical(_dialog, route)) _dialog = null;
    if (approved != true ||
        !_valid(generation) ||
        !interactionCurrent(generation)) {
      return;
    }
    setState(() {
      _origins.add(value.displayName);
      _origin.clear();
      _error = null;
    });
  }

  void _save(int generation) {
    if (!_valid(generation) ||
        _dialog != null ||
        !interactionCurrent(generation)) {
      return;
    }
    final url = dashboardWebsiteUrl(_url.text);
    if (url == null ||
        WebOrigin.parse(url) == null ||
        _title.text.length > 512 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(_title.text)) {
      setState(() => _error = AppLocalizations.of(context).homeInvalidUrl);
      return;
    }
    final origin = WebOrigin.parse(url)!;
    final options = WebPanelOptions(
      additionalOrigins: _origins
          .where((v) => v != origin.displayName)
          .toList(),
      zoomEnabled: _zoom,
      textZoom: _textZoom,
      allowUploads: _uploads,
      allowDownloads: _downloads,
      allowExternalActions: _externalActions,
    );
    _returned = true;
    Navigator.pop(
      context,
      widget.initialTile.copyWith(
        url: url,
        title: _title.text.trim().isEmpty ? null : _title.text.trim(),
        webPanel: options,
      ),
    );
  }

  @override
  void dispose() {
    _url.dispose();
    _title.dispose();
    _origin.dispose();
    super.dispose();
  }

  Widget _bounded(Widget child) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 780),
      child: child,
    ),
  );

  Widget _toggle({
    required Key key,
    required String label,
    required bool value,
    required int generation,
    required ValueChanged<bool> changed,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        FocusableActionDetector(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          },
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                if (_valid(generation)) changed(!value);
                return null;
              },
            ),
          },
          child: Semantics(
            key: key,
            container: true,
            label: label,
            toggled: value,
            onTap: () {
              if (_valid(generation)) changed(!value);
            },
            child: SizedBox(
              width: 60,
              height: 48,
              child: Center(
                child: ExcludeSemantics(
                  child: CupertinoSwitch(
                    value: value,
                    onChanged: (next) {
                      if (_valid(generation)) changed(next);
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    watchDashboardAccount();
    if (ref.exists(pinLockProvider)) {
      ref.listen(pinLockProvider, (previous, next) {
        if (previous != null &&
            (next.isLoading || next.hasError || previous.value != next.value)) {
          setState(() {
            interactionGeneration++;
            invalidateDashboardInteraction();
          });
        }
      });
    }
    final l10n = AppLocalizations.of(context);
    final generation = interactionGeneration;
    final android = defaultTargetPlatform == TargetPlatform.android;
    return ServiceRootScaffold(
      title: l10n.webPanelSettings,
      slivers: [
        if (_expired)
          SliverFilledMessage(child: Text(l10n.dashboardWidgetPickerExpired))
        else
          SliverSafeArea(
            top: false,
            sliver: SliverList.list(
              children: [
                _bounded(
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                    child: Text(l10n.webPanelSessionHint),
                  ),
                ),
                _bounded(
                  SettingsSection(
                    margin: const EdgeInsetsDirectional.fromSTEB(20, 0, 20, 0),
                    header: Semantics(
                      key: const ValueKey('web-settings-content-header'),
                      header: true,
                      child: Text(l10n.webPanelSettings),
                    ),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(l10n.webPanelStartUrl),
                            const SizedBox(height: 8),
                            Semantics(
                              label: l10n.webPanelStartUrl,
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  minHeight: 48,
                                ),
                                child: CupertinoTextField(
                                  key: const ValueKey('web-settings-url'),
                                  controller: _url,
                                  keyboardType: TextInputType.url,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  maxLength: 4096,
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(l10n.webPanelTitle),
                            const SizedBox(height: 8),
                            Semantics(
                              label: l10n.webPanelTitle,
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  minHeight: 48,
                                ),
                                child: CupertinoTextField(
                                  key: const ValueKey('web-settings-title'),
                                  controller: _title,
                                  placeholder: l10n.webPanelTitle,
                                  maxLength: 512,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                _bounded(
                  SettingsSection(
                    margin: const EdgeInsetsDirectional.fromSTEB(20, 0, 20, 0),
                    header: Text(l10n.webPanelOrigins),
                    footer: Text(l10n.webPanelOriginHint),
                    children: [
                      for (final origin in _origins)
                        Row(
                          children: [
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Text(origin),
                              ),
                            ),
                            CupertinoButton(
                              key: ValueKey('web-origin-remove-$origin'),
                              minimumSize: const Size(48, 48),
                              onPressed: dashboardAction(
                                () => setState(() => _origins.remove(origin)),
                              ),
                              child: Text(l10n.commonRemove),
                            ),
                          ],
                        ),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Semantics(
                          label: l10n.webPanelOrigins,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 48),
                            child: CupertinoTextField(
                              key: const ValueKey('web-settings-origin'),
                              controller: _origin,
                              keyboardType: TextInputType.url,
                              autocorrect: false,
                              enableSuggestions: false,
                              placeholder: 'https://login.example.com',
                              maxLength: 4096,
                            ),
                          ),
                        ),
                      ),
                      SettingsActionTile(
                        buttonKey: const ValueKey('web-settings-add-origin'),
                        title: Text(l10n.webPanelOriginAdd),
                        onTap: () => _addOrigin(generation),
                      ),
                    ],
                  ),
                ),
                _bounded(
                  SettingsSection(
                    margin: const EdgeInsetsDirectional.fromSTEB(20, 0, 20, 0),
                    header: Text(l10n.webPanelZoom),
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            Expanded(child: Text(l10n.webPanelZoom)),
                            FocusableActionDetector(
                              shortcuts: const {
                                SingleActivator(LogicalKeyboardKey.enter):
                                    ActivateIntent(),
                                SingleActivator(LogicalKeyboardKey.space):
                                    ActivateIntent(),
                              },
                              actions: {
                                ActivateIntent: CallbackAction<ActivateIntent>(
                                  onInvoke: (_) {
                                    if (_valid(generation)) {
                                      setState(() => _zoom = !_zoom);
                                    }
                                    return null;
                                  },
                                ),
                              },
                              child: Semantics(
                                key: const ValueKey('web-settings-zoom'),
                                container: true,
                                label: l10n.webPanelZoom,
                                toggled: _zoom,
                                onTap: () {
                                  if (_valid(generation)) {
                                    setState(() => _zoom = !_zoom);
                                  }
                                },
                                child: SizedBox(
                                  width: 60,
                                  height: 48,
                                  child: Center(
                                    child: ExcludeSemantics(
                                      child: CupertinoSwitch(
                                        value: _zoom,
                                        onChanged: (value) {
                                          if (_valid(generation)) {
                                            setState(() => _zoom = value);
                                          }
                                        },
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text('${l10n.webPanelTextSize}: $_textZoom%'),
                            if (android)
                              SizedBox(
                                height: 48,
                                child: CupertinoSlider(
                                  key: const ValueKey('web-settings-text-zoom'),
                                  min: 75,
                                  max: 200,
                                  divisions: 5,
                                  value: _textZoom.toDouble(),
                                  onChanged: (value) {
                                    if (_valid(generation)) {
                                      setState(() => _textZoom = value.round());
                                    }
                                  },
                                ),
                              )
                            else
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(l10n.webPanelTextSizeUnsupported),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                _bounded(
                  SettingsSection(
                    margin: const EdgeInsetsDirectional.fromSTEB(20, 0, 20, 0),
                    header: Text(l10n.webPanelTransfers),
                    children: [
                      _toggle(
                        key: const ValueKey('web-settings-uploads'),
                        label: l10n.webPanelUploads,
                        value: _uploads,
                        generation: generation,
                        changed: (value) => setState(() => _uploads = value),
                      ),
                      _toggle(
                        key: const ValueKey('web-settings-downloads'),
                        label: l10n.webPanelDownloads,
                        value: _downloads,
                        generation: generation,
                        changed: (value) => setState(() => _downloads = value),
                      ),
                      _toggle(
                        key: const ValueKey('web-settings-external-actions'),
                        label: l10n.webPanelExternalActions,
                        value: _externalActions,
                        generation: generation,
                        changed: (value) =>
                            setState(() => _externalActions = value),
                      ),
                    ],
                  ),
                ),
                if (_error != null)
                  _bounded(
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: CupertinoColors.systemRed.resolveFrom(context),
                        ),
                      ),
                    ),
                  ),
                _bounded(
                  SettingsSection(
                    margin: const EdgeInsetsDirectional.fromSTEB(20, 0, 20, 0),
                    children: [
                      SettingsActionTile(
                        buttonKey: const ValueKey('web-settings-save'),
                        title: Text(l10n.commonSave),
                        onTap: () => _save(generation),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
