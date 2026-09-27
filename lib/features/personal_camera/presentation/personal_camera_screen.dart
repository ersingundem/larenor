import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/settings_section.dart';
import '../data/personal_camera_controller.dart';
import '../data/personal_camera_platform.dart';

/// Explicit, route-owned local preview. Frames stay inside the native preview
/// surface and are never exposed to Dart, retained, logged, or transmitted.
final class PersonalCameraScreen extends StatefulWidget {
  const PersonalCameraScreen({
    super.key,
    this.platform = const MethodChannelPersonalCameraPlatform(),
  });

  final PersonalCameraPlatform platform;

  @override
  State<PersonalCameraScreen> createState() => _PersonalCameraScreenState();
}

final class _PersonalCameraScreenState extends State<PersonalCameraScreen>
    with WidgetsBindingObserver {
  late final PersonalCameraController _controller;
  AppInteractionController? _interaction;
  int? _viewId;
  bool _foreground = true;
  bool _focused = true;
  bool _routeVisible = true;
  late final Future<PersonalCameraCapabilities> _capabilities;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _controller = PersonalCameraController(
      platform: widget.platform,
      isCurrent: _current,
    )..addListener(_changed);
    _capabilities = widget.platform.capabilities();
  }

  bool _current() {
    if (!mounted) return false;
    try {
      return _foreground &&
          _focused &&
          _routeVisible &&
          _interaction?.active == true &&
          TickerMode.valuesOf(context).enabled &&
          ModalRoute.of(context)?.isCurrent == true;
    } catch (_) {
      return false;
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _viewId ??= View.of(context).viewId;
    final interaction = AppInteractionScope.maybeOf(context);
    if (!identical(interaction, _interaction)) {
      _interaction?.removeListener(_interactionChanged);
      _interaction = interaction?..addListener(_interactionChanged);
    }
    final visible =
        TickerMode.valuesOf(context).enabled &&
        ModalRoute.of(context)?.isCurrent != false;
    if (_routeVisible != visible) {
      _routeVisible = visible;
      if (!visible) unawaited(_controller.close());
    }
    if (_interaction?.active != true) unawaited(_controller.close());
  }

  void _interactionChanged() {
    if (_interaction?.active != true) unawaited(_controller.close());
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) unawaited(_controller.close());
    if (mounted) setState(() {});
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (event.viewId != _viewId) return;
    _focused = event.state == ViewFocusState.focused;
    // A system permission sheet may temporarily own focus before a camera
    // session exists. Once a session exists, any focus loss retires it.
    if (!_focused && _controller.opened) unawaited(_controller.close());
    if (mounted) setState(() {});
  }

  @override
  void didChangeMetrics() {
    if (_controller.opened) unawaited(_controller.close());
  }

  String? _failure(
    AppLocalizations l,
    PersonalCameraFailure? failure,
  ) => switch (failure) {
    null => null,
    PersonalCameraFailure.permissionDenied => l.personalCameraPermissionDenied,
    PersonalCameraFailure.noFrontCamera => l.personalCameraNoFrontCamera,
    PersonalCameraFailure.cameraBusy => l.personalCameraBusy,
    PersonalCameraFailure.batteryCritical => l.personalCameraBatteryCritical,
    PersonalCameraFailure.thermalCritical => l.personalCameraThermalCritical,
    PersonalCameraFailure.unavailable => l.personalCameraUnavailable,
  };

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _interaction?.removeListener(_interactionChanged);
    _controller.removeListener(_changed);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final session = _controller.session;
    final failure = _failure(l, _controller.failure);
    final active = _current();
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l.personalCameraTitle),
      ),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                    child: Text(l.personalCameraIntro, style: AppText.body),
                  ),
                  SettingsSection(
                    header: Text(l.personalCameraTitle),
                    footer: Text(l.personalCameraPrivacy),
                    children: [
                      if (session == null)
                        Padding(
                          padding: const EdgeInsets.all(20),
                          child: Icon(
                            CupertinoIcons.camera_viewfinder,
                            size: 72,
                            color: CupertinoColors.secondaryLabel.resolveFrom(
                              context,
                            ),
                          ),
                        )
                      else
                        Semantics(
                          key: const ValueKey('personal-camera-preview'),
                          image: true,
                          label: l.personalCameraLive,
                          child: AspectRatio(
                            aspectRatio: session.width / session.height,
                            child: ClipRect(
                              child: Transform(
                                alignment: Alignment.center,
                                transform: Matrix4.diagonal3Values(-1, 1, 1),
                                child: Texture(textureId: session.textureId),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  FutureBuilder<PersonalCameraCapabilities>(
                    future: _capabilities,
                    builder: (context, snapshot) {
                      final value = snapshot.data;
                      return SettingsSection(
                        header: Text(l.personalCameraCapabilityTitle),
                        footer: Text(l.personalCameraCapabilityTerms),
                        children: [
                          if (value == null)
                            Padding(
                              padding: const EdgeInsets.all(16),
                              child: snapshot.hasError
                                  ? Text(l.personalCameraCapabilityUnavailable)
                                  : const Center(
                                      child: CupertinoActivityIndicator(),
                                    ),
                            )
                          else ...[
                            _CapabilityRow(
                              label: l.personalCameraCapabilityDevice,
                              value: value.frontCamera && value.preview
                                  ? l.personalCameraCapabilityAvailable
                                  : l.personalCameraCapabilityUnavailable,
                            ),
                            _CapabilityRow(
                              label: l.personalCameraCapabilityDetector,
                              value:
                                  '${value.detectorArtifact}:${value.detectorVersion}',
                            ),
                            _CapabilityRow(
                              label: l.personalCameraCapabilityDelivery,
                              value: value.requiresGooglePlayServices
                                  ? l.personalCameraCapabilityPlayServices
                                  : l.personalCameraCapabilityBundled,
                            ),
                            _CapabilityRow(
                              label: l.personalCameraCapabilityIdentity,
                              value: value.identityRecognition
                                  ? l.personalCameraCapabilityAvailable
                                  : l.personalCameraCapabilityDisabled,
                            ),
                            _CapabilityRow(
                              label: l.personalCameraCapabilityEvaluation,
                              value: value.performanceEvaluation == 'pending'
                                  ? l.personalCameraCapabilityPending
                                  : value.performanceEvaluation,
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                  if (!_foreground || !_focused || !_routeVisible)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Text(l.personalCameraBackground),
                    ),
                  if (failure != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          failure,
                          style: TextStyle(
                            color: CupertinoColors.systemRed.resolveFrom(
                              context,
                            ),
                          ),
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: FocusableActionDetector(
                      enabled: active && !_controller.opening,
                      shortcuts: const {
                        SingleActivator(LogicalKeyboardKey.enter):
                            ActivateIntent(),
                        SingleActivator(LogicalKeyboardKey.space):
                            ActivateIntent(),
                      },
                      actions: {
                        ActivateIntent: CallbackAction<ActivateIntent>(
                          onInvoke: (_) {
                            if (session == null) {
                              unawaited(_controller.open());
                            } else {
                              unawaited(_controller.close());
                            }
                            return null;
                          },
                        ),
                      },
                      child: CupertinoButton.filled(
                        key: ValueKey(
                          session == null
                              ? 'personal-camera-open'
                              : 'personal-camera-close',
                        ),
                        minimumSize: const Size.fromHeight(48),
                        onPressed: !active || _controller.opening
                            ? null
                            : session == null
                            ? _controller.open
                            : _controller.close,
                        child: _controller.opening
                            ? const CupertinoActivityIndicator()
                            : Text(
                                session == null
                                    ? l.personalCameraStart
                                    : l.personalCameraStop,
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _CapabilityRow extends StatelessWidget {
  const _CapabilityRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Text(label, style: AppText.body)),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: AppText.footnote.copyWith(
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
        ),
      ],
    ),
  );
}
