import 'package:shared_preferences/shared_preferences.dart';

enum HomeSource { directLocal, verifiedCore }

abstract interface class HomeSourcePersistence {
  Future<HomeSource> read();
  Future<void> write(HomeSource source);
}

class HomeSourceException implements Exception {
  const HomeSourceException(this.code);

  final String code;

  @override
  String toString() => 'HomeSourceException($code)';
}

class SharedPreferencesHomeSourceStore implements HomeSourcePersistence {
  SharedPreferencesHomeSourceStore({
    Future<SharedPreferences> Function()? loadPreferences,
  });

  static const key = 'home_source_v1';

  @override
  Future<HomeSource> read() async => HomeSource.directLocal;

  @override
  Future<void> write(HomeSource source) async {}
}
