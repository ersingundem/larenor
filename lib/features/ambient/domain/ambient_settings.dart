import 'dart:convert';

enum AmbientPhotoFit { contain, cover }

/// Personal photos are opt-in shared-screen content, separate from the vault.
class AmbientSettings {
  const AmbientSettings({
    this.photosEnabled = false,
    this.showClock = true,
    this.showWeather = true,
    this.pixelShift = true,
    this.intervalSeconds = 30,
    this.fit = AmbientPhotoFit.contain,
  });

  static const preferenceKey = 'ambient_settings_v1';
  static const intervals = [15, 30, 60, 120, 300];
  final bool photosEnabled, showClock, showWeather, pixelShift;
  final int intervalSeconds;
  final AmbientPhotoFit fit;

  AmbientSettings copyWith({
    bool? photosEnabled,
    bool? showClock,
    bool? showWeather,
    bool? pixelShift,
    int? intervalSeconds,
    AmbientPhotoFit? fit,
  }) => AmbientSettings(
    photosEnabled: photosEnabled ?? this.photosEnabled,
    showClock: showClock ?? this.showClock,
    showWeather: showWeather ?? this.showWeather,
    pixelShift: pixelShift ?? this.pixelShift,
    intervalSeconds: intervalSeconds ?? this.intervalSeconds,
    fit: fit ?? this.fit,
  );

  factory AmbientSettings.decode(String value) {
    if (value.length > 2048) throw const AmbientException();
    final data = jsonDecode(value);
    if (data is! Map<String, dynamic> ||
        data.length != 7 ||
        data['version'] != 1 ||
        data['version'] is! int ||
        data['photosEnabled'] is! bool ||
        data['showClock'] is! bool ||
        data['showWeather'] is! bool ||
        data['pixelShift'] is! bool ||
        data['intervalSeconds'] is! int ||
        !intervals.contains(data['intervalSeconds'])) {
      throw const AmbientException();
    }
    final fit = AmbientPhotoFit.values
        .where((v) => v.name == data['fit'])
        .firstOrNull;
    if (fit == null) throw const AmbientException();
    return AmbientSettings(
      photosEnabled: data['photosEnabled'],
      showClock: data['showClock'],
      showWeather: data['showWeather'],
      pixelShift: data['pixelShift'],
      intervalSeconds: data['intervalSeconds'],
      fit: fit,
    );
  }

  String encode() => jsonEncode({
    'version': 1,
    'photosEnabled': photosEnabled,
    'showClock': showClock,
    'showWeather': showWeather,
    'pixelShift': pixelShift,
    'intervalSeconds': intervalSeconds,
    'fit': fit.name,
  });
}

class AmbientException implements Exception {
  const AmbientException({this.limit = false});
  final bool limit;
  @override
  String toString() => 'Ambient content unavailable';
}
