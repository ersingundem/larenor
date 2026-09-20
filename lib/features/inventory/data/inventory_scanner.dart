import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

enum InventoryCameraFailure { permissionDenied, unavailable }

abstract interface class InventoryScannerSession {
  Stream<String> get values;
  Stream<InventoryCameraFailure> get errors;
  Widget preview();
  Future<void> close();
}

abstract interface class InventoryScannerPlatform {
  InventoryScannerSession create();
}

/// Owns exactly one camera flight. Losing lifecycle, rotation or authority
/// closes it; returning to the foreground never resurrects an old reader.
final class InventoryScannerController extends ChangeNotifier {
  InventoryScannerController({
    required this.platform,
    required this.isCurrent,
    required this.onValue,
  });

  final InventoryScannerPlatform platform;
  final bool Function() isCurrent;
  final void Function(String) onValue;
  InventoryScannerSession? _session;
  StreamSubscription<String>? _values;
  StreamSubscription<InventoryCameraFailure>? _errors;
  int _epoch = 0;
  bool _disposed = false, _foreground = true;
  InventoryCameraFailure? failure;

  bool get opened => _session != null;
  bool get manualEntryAvailable => true;
  bool get canOpen => !_disposed && _foreground && _current() && !opened;
  Widget? get preview => _session?.preview();

  bool _current() {
    try {
      return isCurrent();
    } catch (_) {
      return false;
    }
  }

  Future<void> open() async {
    if (!canOpen) return;
    final epoch = ++_epoch;
    failure = null;
    final InventoryScannerSession session;
    try {
      session = platform.create();
    } catch (_) {
      if (!_disposed && epoch == _epoch) {
        failure = InventoryCameraFailure.unavailable;
        notifyListeners();
      }
      return;
    }
    _session = session;
    _values = session.values.listen((value) => _accept(epoch, value));
    _errors = session.errors.listen((error) => _fail(epoch, error));
    notifyListeners();
  }

  Future<void> _accept(int epoch, String value) async {
    if (epoch != _epoch || !_current() || !opened) return;
    final accepted = ++_epoch;
    await _close(invalidate: false);
    if (!_disposed && accepted == _epoch && _current()) onValue(value);
  }

  Future<void> _fail(int epoch, InventoryCameraFailure value) async {
    if (epoch != _epoch || !opened) return;
    failure = value;
    await _close();
  }

  Future<void> onLifecycle(AppLifecycleState state) async {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      await _close();
    } else if (!_disposed) {
      notifyListeners();
    }
  }

  Future<void> onRotation() => _close();

  void synchronizeAuthority() {
    if (!_current()) unawaited(_close());
  }

  Future<void> close() => _close();

  Future<void> _close({bool invalidate = true}) async {
    final session = _session;
    if (session == null) return;
    _session = null;
    if (invalidate) _epoch++;
    await _values?.cancel();
    await _errors?.cancel();
    _values = null;
    _errors = null;
    if (!_disposed) notifyListeners();
    await session.close();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_close());
    super.dispose();
  }
}

final class MobileInventoryScannerPlatform implements InventoryScannerPlatform {
  const MobileInventoryScannerPlatform();
  @override
  InventoryScannerSession create() => _MobileInventoryScannerSession();
}

final class _MobileInventoryScannerSession implements InventoryScannerSession {
  _MobileInventoryScannerSession()
    : _controller = MobileScannerController(
        formats: const [BarcodeFormat.qrCode],
        detectionSpeed: DetectionSpeed.noDuplicates,
      );

  final MobileScannerController _controller;
  final _values = StreamController<String>.broadcast();
  final _errors = StreamController<InventoryCameraFailure>.broadcast();
  bool _closed = false, _attached = false, _disposed = false;

  @override
  Stream<String> get values => _values.stream;
  @override
  Stream<InventoryCameraFailure> get errors => _errors.stream;

  @override
  Widget preview() => _MobileInventoryScannerPreview(this);

  Widget buildScanner() => MobileScanner(
    controller: _controller,
    onDetect: (capture) {
      if (_closed) return;
      for (final barcode in capture.barcodes) {
        final value = barcode.rawValue;
        if (value != null) {
          _values.add(value);
          break;
        }
      }
    },
    errorBuilder: (context, error) {
      if (!_closed) {
        scheduleMicrotask(() {
          if (_closed || _errors.isClosed) return;
          _errors.add(
            error.errorCode == MobileScannerErrorCode.permissionDenied
                ? InventoryCameraFailure.permissionDenied
                : InventoryCameraFailure.unavailable,
          );
        });
      }
      return const SizedBox.shrink();
    },
  );

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_controller.value.isInitialized) await _controller.stop();
    await _values.close();
    await _errors.close();
    if (!_attached) await disposeController();
  }

  Future<void> disposeController() async {
    if (_disposed) return;
    _disposed = true;
    await _controller.dispose();
  }
}

final class _MobileInventoryScannerPreview extends StatefulWidget {
  const _MobileInventoryScannerPreview(this.session);
  final _MobileInventoryScannerSession session;

  @override
  State<_MobileInventoryScannerPreview> createState() =>
      _MobileInventoryScannerPreviewState();
}

final class _MobileInventoryScannerPreviewState
    extends State<_MobileInventoryScannerPreview> {
  @override
  void initState() {
    super.initState();
    widget.session._attached = true;
  }

  @override
  void dispose() {
    widget.session._attached = false;
    unawaited(widget.session.disposeController());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.session.buildScanner();
}
