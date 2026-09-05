import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Tests have no platform Keychain/Keystore. Start each test-file isolate with
  // an empty device store; explicit corruption/failure tests replace this seam.
  FlutterSecureStorage.setMockInitialValues({});
  await testMain();
}
