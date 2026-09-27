import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/cupertino.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../domain/kiosk_peripheral_contract.dart';

final class KioskPeripheralQrSample {
  const KioskPeripheralQrSample({
    required this.rawInput,
    required this.nowElapsedMs,
  });

  final Object rawInput;
  final int nowElapsedMs;
}

abstract interface class KioskPeripheralQrCapture {
  Future<String?> capture(BuildContext context);

  KioskPeripheralQrSample seal({
    required String payload,
    required KioskPeripheralCapability provider,
    required KioskPeripheralAuthority authority,
  });
}

/// Opens one local camera flight and converts the result into a review-only
/// K11 envelope. The scanned value is never opened, executed, or forwarded.
final class MobileKioskPeripheralQrCapture implements KioskPeripheralQrCapture {
  MobileKioskPeripheralQrCapture();

  static final Stopwatch _clock = Stopwatch()..start();
  final Random _random = Random.secure();
  final Map<String, ({Digest digest, int elapsedMs})> _recent = {};
  int _sequence = 0;

  @override
  Future<String?> capture(BuildContext context) => Navigator.of(context).push(
    CupertinoPageRoute<String>(
      fullscreenDialog: true,
      builder: (_) => const _KioskPeripheralQrCaptureScreen(),
    ),
  );

  @override
  KioskPeripheralQrSample seal({
    required String payload,
    required KioskPeripheralCapability provider,
    required KioskPeripheralAuthority authority,
  }) {
    final bytes = utf8.encode(payload);
    if (provider.providerId != 'qr.camera' ||
        provider.kind != KioskPeripheralKind.qr ||
        !provider.acceptsInput ||
        !authority.valid ||
        bytes.isEmpty ||
        bytes.length > provider.maxPayloadBytes ||
        payload.contains('\u0000')) {
      throw const FormatException('invalid qr review input');
    }
    final now = _clock.elapsedMilliseconds;
    final digest = sha256.convert(bytes);
    final previous = _recent[provider.providerId];
    if (previous != null &&
        previous.digest == digest &&
        now - previous.elapsedMs <= 2000) {
      throw const FormatException('duplicate qr review input');
    }
    _recent[provider.providerId] = (digest: digest, elapsedMs: now);
    if (_sequence >= 0x7ffffffe) {
      throw StateError('qr_sequence_exhausted');
    }
    final sequence = ++_sequence;
    final eventId = List<int>.generate(
      16,
      (_) => _random.nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    return KioskPeripheralQrSample(
      nowElapsedMs: _clock.elapsedMilliseconds,
      rawInput: <String, Object?>{
        'schemaVersion': 1,
        'eventId': eventId,
        'providerId': provider.providerId,
        'kind': KioskPeripheralKind.qr.name,
        'capabilityRevision': provider.revision,
        'deviceRevision': authority.deviceRevision,
        'policyRevision': authority.policyRevision,
        'sessionEpoch': authority.sessionEpoch,
        'routeEpoch': authority.routeEpoch,
        'lifecycleEpoch': authority.lifecycleEpoch,
        'sequence': sequence,
        'capturedAtElapsedMs': now,
        'payload': payload,
      },
    );
  }
}

final class _KioskPeripheralQrCaptureScreen extends StatefulWidget {
  const _KioskPeripheralQrCaptureScreen();

  @override
  State<_KioskPeripheralQrCaptureScreen> createState() =>
      _KioskPeripheralQrCaptureScreenState();
}

final class _KioskPeripheralQrCaptureScreenState
    extends State<_KioskPeripheralQrCaptureScreen>
    with WidgetsBindingObserver {
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_close());
  }

  Future<void> _close([String? value]) async {
    if (_closing) return;
    _closing = true;
    if (_controller.value.isInitialized) await _controller.stop();
    if (mounted) Navigator.of(context).pop(value);
  }

  void _detect(BarcodeCapture capture) {
    if (_closing) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value != null && value.isNotEmpty) {
        unawaited(_close(value));
        return;
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l.kioskPeripheralQr),
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _close,
          child: Text(l.commonCancel),
        ),
      ),
      child: SafeArea(
        child: MobileScanner(
          key: const ValueKey('kiosk-peripheral-qr-camera'),
          controller: _controller,
          onDetect: _detect,
          errorBuilder: (context, error) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(l.kioskPeripheralUnavailable),
            ),
          ),
        ),
      ),
    );
  }
}
