import 'package:media_kit/media_kit.dart';

/// A local Jellyfin user's preferred languages, never a claim that a stream
/// actually contains a requested audio or subtitle track.
final class JellyfinTrackPreferenceRecord {
  const JellyfinTrackPreferenceRecord({
    required this.audioLanguage,
    required this.subtitleLanguage,
  });

  final String? audioLanguage;
  final String? subtitleLanguage;
}

abstract final class JellyfinTrackPreferences {
  static final _language = RegExp(r'^[a-z]{2,3}(?:-[a-z]{2}|-[0-9]{3})?$');
  static const _iso639Aliases = {
    'eng': 'en',
    'tur': 'tr',
    'deu': 'de',
    'ger': 'de',
    'fra': 'fr',
    'fre': 'fr',
    'spa': 'es',
    'ita': 'it',
    'por': 'pt',
    'nld': 'nl',
    'dut': 'nl',
    'jpn': 'ja',
    'kor': 'ko',
    'zho': 'zh',
    'chi': 'zh',
    'rus': 'ru',
  };

  static String? normalize(String? value, {bool allowOff = false}) {
    if (value == null) return null;
    final result = value.trim().toLowerCase();
    if (allowOff && result == 'off') return result;
    if (!_language.hasMatch(result)) {
      throw const FormatException('Invalid language');
    }
    final parts = result.split('-');
    parts[0] = _iso639Aliases[parts[0]] ?? parts[0];
    return parts.join('-');
  }

  static bool _matches(String? actual, String expected, {required bool exact}) {
    if (actual == null) return false;
    String? normalized;
    try {
      normalized = normalize(actual);
    } on FormatException {
      return false;
    }
    if (normalized == null) return false;
    return normalized == expected ||
        (!exact && normalized.split('-').first == expected.split('-').first);
  }

  static AudioTrack? audio(List<AudioTrack> tracks, String? language) {
    final preferred = normalize(language);
    if (preferred == null) return null;
    for (final exact in [true, false]) {
      for (final track in tracks) {
        if (track.id != 'auto' &&
            track.id != 'no' &&
            _matches(track.language, preferred, exact: exact)) {
          return track;
        }
      }
    }
    return null;
  }

  static SubtitleTrack? subtitle(List<SubtitleTrack> tracks, String? language) {
    final preferred = normalize(language, allowOff: true);
    if (preferred == null) return null;
    if (preferred == 'off') return SubtitleTrack.no();
    for (final exact in [true, false]) {
      for (final track in tracks) {
        if (track.id != 'auto' &&
            track.id != 'no' &&
            _matches(track.language, preferred, exact: exact)) {
          return track;
        }
      }
    }
    return null;
  }
}
