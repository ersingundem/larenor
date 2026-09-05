import 'package:shared_preferences/shared_preferences.dart';

import '../domain/screen_program.dart';

abstract interface class ScreenProgramStore {
  Future<String?> read();
  Future<void> write(String value);
}

class PreferenceScreenProgramStore implements ScreenProgramStore {
  @override
  Future<String?> read() async {
    final value = (await SharedPreferences.getInstance()).get(
      ScreenProgram.preferenceKey,
    );
    if (value != null && value is! String) {
      throw const FormatException('Invalid screen program');
    }
    return value as String?;
  }

  @override
  Future<void> write(String value) async {
    if (!await (await SharedPreferences.getInstance()).setString(
      ScreenProgram.preferenceKey,
      value,
    )) {
      throw StateError('Screen program could not be saved');
    }
  }
}
