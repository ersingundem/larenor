import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:larenor/core/window/window_policy_bridge.dart';
import 'package:larenor/core/window/window_policy_models.dart';
import 'package:larenor/features/kiosk/data/kiosk_api.dart';
import 'package:larenor/features/kiosk/domain/kiosk_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Run through tool/run_android_e2e.sh only: it verifies the caller's explicit
// disposable emulator serial and ro.kernel.qemu before installing this target.
// This file deliberately does not use AppHarness or any platform mock. Missing
// plugins/unsupported native responses fail; they must never become skips.
// Fresh Dart clients prove a native roundtrip in one app process, not survival
// of process death, reinstall, key invalidation, or hardware-backed encryption.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    if (!const bool.fromEnvironment('LARENOR_E2E') || !Platform.isAndroid) {
      throw StateError(
        'Run this target with the disposable Android emulator E2E runner.',
      );
    }
  });

  testWidgets(
    'native secure storage survives a fresh client and deletes only its probe',
    (tester) async {
      // Isolate data, algorithm markers, wrapping keys and Keystore aliases from
      // the app's real store. Never recover a plugin error by resetting storage.
      const options = AndroidOptions(
        storageNamespace: 'larenor_e2e_platform',
        resetOnError: false,
      );
      const channel = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      final key = _probeKey('secure');
      const value = 'synthetic storage roundtrip';
      final writer = FlutterSecureStorage(aOptions: options);
      try {
        expect(await writer.containsKey(key: key), isFalse);
        await writer.write(key: key, value: value);
        final reader = FlutterSecureStorage(aOptions: options);
        expect(identical(writer, reader), isFalse);
        expect(await reader.read(key: key) == value, isTrue);
        expect(await reader.containsKey(key: key), isTrue);

        // Independently cross the real plugin channel. A future accidental
        // in-memory FlutterSecureStorage override must not produce a green test.
        final nativeValue = await channel.invokeMethod<String>('read', {
          'key': key,
          'options': options.toMap(),
        });
        expect(nativeValue == value, isTrue);
        await reader.delete(key: key);
        final afterDelete = FlutterSecureStorage(aOptions: options);
        expect(await afterDelete.read(key: key) == null, isTrue);
        expect(await afterDelete.containsKey(key: key), isFalse);
        final nativeAfterDelete = await channel.invokeMethod<String>('read', {
          'key': key,
          'options': options.toMap(),
        });
        expect(nativeAfterDelete == null, isTrue);
      } finally {
        await writer.delete(key: key);
      }
    },
  );

  testWidgets(
    'native legacy preferences survive an uncached client and scoped removal',
    (tester) async {
      // Exercise the same legacy API used by app settings, but return only the
      // fixture namespace from the native getAll operation. resetStatic resets
      // the Dart cache; it neither replaces the plugin nor clears native data.
      const prefix = 'larenor_e2e.platform.';
      final key = _probeKey('preferences');
      Future<SharedPreferences> fresh() {
        SharedPreferences.resetStatic();
        SharedPreferences.setPrefix(prefix, allowList: {'$prefix$key'});
        return SharedPreferences.getInstance();
      }

      final writer = await fresh();
      try {
        expect(writer.containsKey(key), isFalse);
        expect(await writer.setString(key, 'synthetic preference'), isTrue);
        final reader = await fresh();
        expect(identical(writer, reader), isFalse);
        expect(reader.getString(key) == 'synthetic preference', isTrue);
        expect(await reader.remove(key), isTrue);
        final afterDelete = await fresh();
        expect(afterDelete.getString(key) == null, isTrue);
        expect(afterDelete.containsKey(key), isFalse);
      } finally {
        await writer.remove(key);
        SharedPreferences.resetStatic();
      }
    },
  );

  testWidgets(
    'native asynchronous preferences read and remove their exact key',
    (tester) async {
      // This uncached API reads its individual key from the native backend on
      // each call; no all-preferences read or unscoped clear is performed.
      final key = 'larenor_e2e.platform.${_probeKey('async')}';
      final writer = SharedPreferencesAsync();
      try {
        expect(await writer.containsKey(key), isFalse);
        await writer.setInt(key, 73);
        final reader = SharedPreferencesAsync();
        expect(identical(writer, reader), isFalse);
        expect(await reader.getInt(key), 73);
        await reader.remove(key);
        final afterDelete = SharedPreferencesAsync();
        expect(await afterDelete.getInt(key), isNull);
        expect(await afterDelete.containsKey(key), isFalse);
      } finally {
        await writer.remove(key);
      }
    },
  );

  testWidgets(
    'native kiosk and window snapshots report an unmanaged foreground activity',
    (tester) async {
      await tester.pumpWidget(
        const CupertinoApp(
          home: CupertinoPageScaffold(
            child: Center(child: Text('Synthetic platform checks')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Read-only: no prepare/execute, startLockTask, allowlist, admin enrollment,
      // profile change, permission request, or power setting is invoked.
      var kiosk = await AndroidKioskApi().snapshot();
      var window = await WindowPolicyBridge().snapshot();
      // Flutter settling does not establish native window focus: the Android
      // activity can still be receiving its focus callback after launch. Wait
      // for that observable state, then keep every foreground assertion below.
      final focusDeadline = DateTime.now().add(const Duration(seconds: 5));
      while ((!kiosk.resumed ||
              !kiosk.focused ||
              !window.isResumed ||
              !window.hasWindowFocus) &&
          DateTime.now().isBefore(focusDeadline)) {
        await tester.pump(const Duration(milliseconds: 100));
        kiosk = await AndroidKioskApi().snapshot();
        window = await WindowPolicyBridge().snapshot();
      }
      if (!kiosk.resumed ||
          !kiosk.focused ||
          !window.isResumed ||
          !window.hasWindowFocus ||
          kiosk.keyguardLocked != false) {
        // The CI-only runner watches this static marker and captures one
        // filtered emulator screen/window/power snapshot at the failure.
        // Booleans/enums only: no storage values or application data are logged.
        debugPrint(
          'LARENOR_E2E_NATIVE_FOCUS_FAILURE '
          'kioskResumed=${kiosk.resumed} kioskFocused=${kiosk.focused} '
          'keyguardLocked=${kiosk.keyguardLocked} '
          'windowResumed=${window.isResumed} windowFocused=${window.hasWindowFocus} '
          'windowReason=${window.reason.name}',
          wrapWidth: 1024,
        );
      }
      expect(kiosk.supported, isTrue);
      expect(kiosk.deviceOwner, isFalse);
      expect(kiosk.permitted, isFalse);
      expect(kiosk.lockState, KioskLockState.none);
      expect(kiosk.actions, isEmpty);
      expect(kiosk.resumed, isTrue);
      expect(kiosk.focused, isTrue);
      expect(kiosk.keyguardLocked, isFalse);

      expect(window.supported, isTrue);
      expect(window.effectiveMode, WindowEffectiveMode.adaptive);
      expect(window.requestedProfile, WindowProfile.adaptive);
      expect(window.reason, WindowRestrictionReason.none);
      expect(window.isResumed, isTrue);
      expect(window.hasWindowFocus, isTrue);
      expect(window.lockTaskPermitted, isFalse);
      expect(window.lockTaskState, WindowLockTaskState.none);
      expect(window.isMultiWindow, isFalse);
      expect(window.isPictureInPicture, isFalse);
      expect(window.isExternalDisplay, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

String _probeKey(String name) =>
    '${name}_${DateTime.now().microsecondsSinceEpoch}';
