import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../domain/local_audio_models.dart';
import '../providers/local_audio_providers.dart';

class LocalAudioArtworkView extends ConsumerWidget {
  const LocalAudioArtworkView({required this.snapshot, super.key});
  final LocalAudioSnapshot snapshot;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = TickerMode.valuesOf(context).enabled;
    final sourceId = snapshot.sourceId;
    final artworkId = snapshot.artworkId;
    final reading =
        active &&
            sourceId != null &&
            artworkId != null &&
            snapshot.artworkState == LocalAudioArtworkState.ready
        ? ref.watch(
            localAudioArtworkProvider((
              sourceId: sourceId,
              artworkId: artworkId,
            )),
          )
        : null;
    final data = reading == null || reading.isLoading || reading.hasError
        ? null
        : reading.value;
    final failed =
        snapshot.artworkState == LocalAudioArtworkState.failed ||
        reading?.hasError == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LocalAudioCover(
          artwork: data,
          imageKey: ValueKey('local-audio-cover-$sourceId-$artworkId'),
        ),
        if (snapshot.artworkState == LocalAudioArtworkState.loading)
          Text(
            AppLocalizations.of(context).localAudioArtworkLoading,
            style: AppText.footnote,
          ),
        if (failed)
          Text(
            AppLocalizations.of(context).localAudioArtworkInvalid,
            style: AppText.footnote,
          ),
      ],
    );
  }
}

/// Decorative beside the real media title. Never crops faces or stretches art;
/// arbitrary cover colours cannot reduce the contrast of playback controls.
class LocalAudioCover extends StatelessWidget {
  const LocalAudioCover({required this.artwork, this.imageKey, super.key});
  final LocalAudioArtwork? artwork;
  final Key? imageKey;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 176),
      child: AspectRatio(
        aspectRatio: 1,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: ColoredBox(
            color: CupertinoColors.tertiarySystemFill.resolveFrom(context),
            child: artwork == null
                ? _fallback()
                : Image.memory(
                    artwork!.bytes,
                    key: imageKey,
                    fit: BoxFit.contain,
                    cacheWidth: artwork!.width,
                    gaplessPlayback: false,
                    errorBuilder: (_, _, _) => _fallback(),
                  ),
          ),
        ),
      ),
    ),
  );
  Widget _fallback() =>
      const Center(child: Icon(CupertinoIcons.music_note_2, size: 44));
}
