import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/app_interaction_scope.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/app_page_scaffold.dart';
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
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.webPanelSettings),
      ),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 780),
            child: _expired
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(l10n.dashboardWidgetPickerExpired),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      Text(l10n.webPanelSessionHint),
                      const SizedBox(height: 20),
                      Text(l10n.webPanelStartUrl),
                      const SizedBox(height: 8),
                      CupertinoTextField(
                        key: const ValueKey('web-settings-url'),
                        controller: _url,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        enableSuggestions: false,
                        maxLength: 4096,
                      ),
                      const SizedBox(height: 16),
                      Text(l10n.webPanelTitle),
                      const SizedBox(height: 8),
                      CupertinoTextField(
                        key: const ValueKey('web-settings-title'),
                        controller: _title,
                        maxLength: 512,
                      ),
                      const SizedBox(height: 24),
                      Text(
                        l10n.webPanelOrigins,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      Text(l10n.webPanelOriginHint),
                      for (final origin in _origins)
                        Row(
                          children: [
                            Expanded(child: Text(origin)),
                            CupertinoButton(
                              key: ValueKey('web-origin-remove-$origin'),
                              onPressed: dashboardAction(
                                () => setState(() => _origins.remove(origin)),
                              ),
                              child: Text(l10n.commonRemove),
                            ),
                          ],
                        ),
                      const SizedBox(height: 12),
                      CupertinoTextField(
                        key: const ValueKey('web-settings-origin'),
                        controller: _origin,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        enableSuggestions: false,
                        placeholder: 'https://login.example.com',
                        maxLength: 4096,
                      ),
                      CupertinoButton(
                        onPressed: () => _addOrigin(generation),
                        child: Text(l10n.webPanelOriginAdd),
                      ),
                      const SizedBox(height: 16),
                      MergeSemantics(
                        child: Row(
                          children: [
                            Expanded(child: Text(l10n.webPanelZoom)),
                            CupertinoSwitch(
                              key: const ValueKey('web-settings-zoom'),
                              value: _zoom,
                              onChanged: (value) {
                                if (_valid(generation)) {
                                  setState(() => _zoom = value);
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text('${l10n.webPanelTextSize}: $_textZoom%'),
                      if (android)
                        CupertinoSlider(
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
                        )
                      else
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(l10n.webPanelTextSizeUnsupported),
                        ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: CupertinoColors.systemRed.resolveFrom(
                                context,
                              ),
                            ),
                          ),
                        ),
                      const SizedBox(height: 20),
                      CupertinoButton.filled(
                        key: const ValueKey('web-settings-save'),
                        onPressed: () => _save(generation),
                        child: Text(l10n.commonSave),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
