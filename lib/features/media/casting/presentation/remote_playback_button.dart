import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../hub/presentation/media_session_state.dart';
import '../../jellyfin/providers/jellyfin_providers.dart';
import 'remote_playback_screen.dart';

/// Navigation only. Receiver discovery and content validation begin only after
/// the user opens the target screen.
class RemotePlaybackButton extends ConsumerStatefulWidget {
  const RemotePlaybackButton({
    super.key,
    required this.itemId,
    this.enabled = true,
  });
  final String itemId;
  final bool enabled;
  @override
  ConsumerState<RemotePlaybackButton> createState() =>
      _RemotePlaybackButtonState();
}

class _RemotePlaybackButtonState
    extends MediaSessionState<RemotePlaybackButton> {
  bool _opening = false;
  @override
  void clearPendingInteraction() => _opening = false;
  @override
  Widget build(BuildContext context) {
    watchMediaAccounts(jellyfinOnly: true);
    final config = ref.watch(jellyfinConnectionProvider);
    final generation = sessionGeneration;
    final id = widget.itemId;
    return CupertinoButton(
      key: const ValueKey('media-remote-play'),
      padding: const EdgeInsets.symmetric(vertical: 12),
      onPressed:
          !widget.enabled ||
              !foreground ||
              sessionExpired ||
              _opening ||
              config.isLoading ||
              config.hasError ||
              config.value == null
          ? null
          : () async {
              if (!sessionCurrent(generation) ||
                  _opening ||
                  id != widget.itemId ||
                  ModalRoute.of(context)?.isCurrent != true) {
                return;
              }
              setState(() => _opening = true);
              await Navigator.of(context).push(
                CupertinoPageRoute<void>(
                  builder: (_) => RemotePlaybackScreen(itemId: id),
                ),
              );
              if (mounted) {
                setState(() => _opening = false);
              }
            },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(CupertinoIcons.tv, size: 20),
          const SizedBox(width: 8),
          Flexible(child: Text(AppLocalizations.of(context).mediaRemoteTitle)),
        ],
      ),
    );
  }
}
