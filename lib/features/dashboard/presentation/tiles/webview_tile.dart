import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/direct_home_access.dart';
import '../../../../core/home_session_controller.dart';
import '../../../../core/home_source_store.dart';
import '../../../web_panel/data/web_panel_native_effect_port.dart';
import '../../../web_panel/data/web_panel_native_runtime.dart';
import '../../../web_panel/domain/web_panel_policy.dart';
import '../../../web_panel/presentation/web_panel_view.dart';
import '../../domain/tile_config.dart';

/// A Direct-home website reference. Browser login remains separate from HA
/// credentials and the device-shared WebView data store is never cleared here.
class WebviewTile extends ConsumerStatefulWidget {
  const WebviewTile({super.key, required this.tile});
  final TileConfig tile;

  @override
  ConsumerState<WebviewTile> createState() => _WebviewTileState();
}

class _WebviewTileState extends ConsumerState<WebviewTile> {
  // Retain this owner for the whole widget lifetime: a source round trip cannot
  // give an old tile or its native callbacks a newly created Direct capability.
  late final DirectHomeAccess _access = ref.read(directHomeAccessProvider);
  bool _retired = false;
  Object? _coreBinding;
  AndroidWebPanelNativeEffectPort? _nativePort;

  bool get _sourceCurrent {
    if (!mounted || _retired) return false;
    if (!_access.isCurrent ||
        !identical(ref.read(directHomeAccessProvider), _access)) {
      _retired = true;
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final home = ref.watch(homeSessionControllerProvider);
    final session = home?.account.session;
    final nativePolicy = widget.tile.webPanel?.nativeBridge;
    WebPanelNativeAuthorityLease? authority;
    AndroidWebPanelNativeEffectPort? port;
    bool Function() current = () => _sourceCurrent;
    if (home?.source == HomeSource.verifiedCore &&
        session?.context != null &&
        session!.sessionFamilyId != null &&
        nativePolicy != null &&
        home!.interaction.active) {
      final identity = home.runtimeIdentity;
      final generation = home.account.generation;
      final interactionEpoch = home.interaction.epoch;
      final binding = (
        identity,
        generation,
        interactionEpoch,
        session,
        widget.tile.id,
        nativePolicy.revision,
      );
      bool coreCurrent() {
        try {
          return mounted &&
              identical(ref.read(homeSessionControllerProvider), home) &&
              home.source == HomeSource.verifiedCore &&
              home.runtimeIdentity == identity &&
              home.interaction.active &&
              home.interaction.epoch == interactionEpoch &&
              home.account.isCurrent(generation) &&
              identical(home.account.session, session) &&
              widget.tile.webPanel?.nativeBridge == nativePolicy;
        } catch (_) {
          return false;
        }
      }

      if (_coreBinding != binding) {
        _coreBinding = binding;
        _nativePort = AndroidWebPanelNativeEffectPort();
      }
      current = coreCurrent;
      port = _nativePort;
      authority = WebPanelNativeAuthorityLease.verifiedCore(
        coreId: session.context!.coreId,
        homeId: session.context!.homeId,
        accountId: session.user.id,
        sessionFamily: session.sessionFamilyId!,
        sourceId: widget.tile.id,
        sourceRevision: nativePolicy.revision,
        isCurrent: coreCurrent,
      );
    } else {
      _coreBinding = null;
      _nativePort = null;
    }
    if (!current()) return const SizedBox.shrink();
    final tile = widget.tile;
    return WebPanelView(
      policy:
          tile.webPanel?.policyFor(tile.url ?? '') ??
          WebPanelPolicy.fromUrl(tile.url ?? ''),
      sourceIdentity: (_access, tile.id),
      sourceCurrent: current,
      options: tile.webPanel,
      nativeAuthority: authority,
      nativePort: port,
    );
  }
}
