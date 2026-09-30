import 'package:flutter/services.dart';

/// Platform output is untrusted text. Only an explicit Core preview parses it.
final class LocalDraftSpeech {
  const LocalDraftSpeech();
  static const _channel = MethodChannel('com.ersingundem.larenor/local_speech');

  Future<({bool available, bool microphoneGranted})> probe() async {
    final value = await _channel.invokeMethod<Object?>('probe');
    if (value is! Map ||
        value.length != 3 ||
        value['schemaVersion'] != 1 ||
        value['onDeviceAvailable'] is! bool ||
        value['microphoneGranted'] is! bool) {
      throw const FormatException('invalid_speech_response');
    }
    return (
      available: value['onDeviceAvailable'] as bool,
      microphoneGranted: value['microphoneGranted'] as bool,
    );
  }

  Future<bool> requestPermission() async {
    final result = await _channel.invokeMethod<Object?>('requestPermission');
    if (result is! bool) {
      throw const FormatException('invalid_speech_response');
    }
    return result;
  }

  Future<String> recognize(String locale) async {
    final value = await _channel.invokeMethod<Object?>('recognize', {
      'locale': locale,
    });
    _receipt(value);
    final text = (value as Map)['text'];
    if (text is! String || !validText(text)) {
      throw const FormatException('invalid_speech_response');
    }
    return text;
  }

  Future<void> speak(String locale, String text) async {
    if (!validText(text)) throw const FormatException('invalid_transcript');
    final value = await _channel.invokeMethod<Object?>('speak', {
      'locale': locale,
      'text': text,
    });
    _receipt(value);
    if ((value as Map)['text'] != null) {
      throw const FormatException('invalid_speech_response');
    }
  }

  static void _receipt(Object? value) {
    if (value is! Map ||
        value.length != 3 ||
        value['schemaVersion'] != 1 ||
        value['onDevice'] != true ||
        !value.containsKey('text')) {
      throw const FormatException('invalid_speech_response');
    }
  }

  static bool validText(String text) =>
      text.trim().isNotEmpty &&
      text.length <= 256 &&
      !RegExp(
        r'[\x00-\x1f\x7f-\x9f\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]',
      ).hasMatch(text);

  Future<void> cancel() async {
    try {
      await _channel.invokeMethod<void>('cancel');
    } on PlatformException {
      // Local retirement must not surface raw provider errors.
    } on MissingPluginException {
      // Other platforms use the explicit text path.
    }
  }
}
