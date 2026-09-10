import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/remote_profiles.dart';
import 'sftp_engine.dart';
import 'sftp_file_access.dart';
import 'sftp_models.dart';
import 'ssh_security_store.dart';

enum SftpPhase {
  idle,
  connecting,
  hostKey,
  ready,
  listing,
  downloading,
  uploading,
  closed,
  failed,
}

class SftpController extends ChangeNotifier {
  SftpController({
    required this.profile,
    required this.store,
    required this.engineFactory,
    required this.fileAccess,
    required this.isCurrent,
    this.connectTimeout = const Duration(seconds: 45),
  });

  final RemoteProfile profile;
  final SshSecurityStore store;
  final SftpEngine Function() engineFactory;
  final SftpFileAccess fileAccess;
  final bool Function() isCurrent;
  final Duration connectTimeout;

  SftpPhase phase = SftpPhase.idle;
  SshHostPin? pendingPin;
  String path = '/';
  List<SftpEntry> entries = const [];
  bool truncated = false;
  int progress = 0;
  String? error;
  String? notice;

  SftpEngine? _engine;
  SftpTransport? _transport;
  Completer<bool>? _decision;
  Timer? _timer;
  int _generation = 0;
  bool _retired = false;
  bool _disposed = false;

  bool _current(int generation) {
    try {
      return !_retired &&
          !_disposed &&
          generation == _generation &&
          isCurrent();
    } catch (_) {
      return false;
    }
  }

  void _check(int generation) {
    if (!_current(generation)) throw const SftpFailure('retired');
  }

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  void _closeResources() {
    _timer?.cancel();
    _timer = null;
    if (_decision?.isCompleted == false) _decision!.complete(false);
    _decision = null;
    pendingPin = null;
    _transport?.close();
    _transport = null;
    _engine?.close();
    _engine = null;
    progress = 0;
  }

  void _end({String? code}) {
    _generation++;
    _closeResources();
    entries = const [];
    truncated = false;
    notice = null;
    error = code;
    phase = code == null ? SftpPhase.closed : SftpPhase.failed;
    _publish();
  }

  @override
  void dispose() {
    _disposed = true;
    _retired = true;
    _generation++;
    _closeResources();
    entries = const [];
    super.dispose();
  }

  Future<void> connect() async {
    if (_retired ||
        _disposed ||
        phase == SftpPhase.connecting ||
        phase == SftpPhase.hostKey ||
        phase == SftpPhase.ready ||
        phase == SftpPhase.listing ||
        phase == SftpPhase.downloading ||
        phase == SftpPhase.uploading) {
      return;
    }
    _generation++;
    final generation = _generation;
    _closeResources();
    entries = const [];
    path = '/';
    truncated = false;
    error = null;
    notice = null;
    phase = SftpPhase.connecting;
    _publish();
    _timer = Timer(connectTimeout, () {
      if (generation == _generation) _end(code: 'timed_out');
    });
    try {
      await store.checkProfile(profile, isCurrent: () => _current(generation));
      _check(generation);
      final credential = await store.readCredential(
        profile,
        isCurrent: () => _current(generation),
      );
      _check(generation);
      if (credential == null) throw const SftpFailure('credential_missing');
      final engine = engineFactory();
      _engine = engine;
      final transport = await engine.open(
        profile,
        credential,
        isCurrent: () => _current(generation),
        verifyHost: (pin) async {
          _check(generation);
          final old = await store.readPin(
            profile,
            isCurrent: () => _current(generation),
          );
          _check(generation);
          if (old != null) {
            if (old.type != pin.type || old.fingerprint != pin.fingerprint) {
              throw const SftpFailure('host_changed');
            }
            return true;
          }
          final decision = _decision = Completer<bool>();
          pendingPin = pin;
          phase = SftpPhase.hostKey;
          _publish();
          final accepted = await decision.future;
          _check(generation);
          return accepted;
        },
      );
      _check(generation);
      _transport = transport;
      _timer?.cancel();
      _timer = null;
      pendingPin = null;
      phase = SftpPhase.ready;
      _publish();
      unawaited(
        transport.done.then(
          (_) {
            if (generation == _generation && !_disposed) {
              _end(code: 'connection_lost');
            }
          },
          onError: (Object _) {
            if (generation == _generation && !_disposed) {
              _end(code: 'connection_lost');
            }
          },
        ),
      );
    } catch (exception) {
      if (generation != _generation || _disposed) return;
      if (!_current(generation)) {
        retire();
      } else {
        _end(
          code: exception is SftpFailure
              ? exception.code
              : exception is SshFailure
              ? exception.code
              : 'connection_failed',
        );
      }
    }
  }

  Future<void> trustHost() async {
    final generation = _generation;
    final decision = _decision;
    final pin = pendingPin;
    if (phase != SftpPhase.hostKey ||
        decision == null ||
        decision.isCompleted ||
        pin == null) {
      return;
    }
    try {
      await store.trust(profile, pin, isCurrent: () => _current(generation));
      _check(generation);
      pendingPin = null;
      phase = SftpPhase.connecting;
      decision.complete(true);
      _publish();
    } catch (exception) {
      if (generation == _generation) {
        _end(code: exception is SshFailure ? exception.code : 'storage_failed');
      }
    }
  }

  Future<void> openDirectory(String requested) async {
    if (phase != SftpPhase.ready) return;
    final generation = _generation;
    try {
      final normalized = normalizeSftpPath(requested, base: path);
      phase = SftpPhase.listing;
      error = null;
      notice = null;
      _publish();
      await store.checkProfile(profile, isCurrent: () => _current(generation));
      _check(generation);
      final listing = await _transport!.list(
        normalized,
        maxEntries: sftpMaxEntries,
        isCurrent: () => _current(generation),
      );
      _check(generation);
      final sorted = [...listing.entries]
        ..sort((a, b) {
          if (a.kind != b.kind) return a.isDirectory ? -1 : 1;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
      path = normalized;
      entries = List.unmodifiable(sorted);
      truncated = listing.truncated;
      phase = SftpPhase.ready;
      _publish();
    } catch (exception) {
      if (generation == _generation) {
        _end(code: exception is SftpFailure ? exception.code : 'list_failed');
      }
    }
  }

  Future<void> download(SftpEntry entry) async {
    if (phase != SftpPhase.ready || entry.isDirectory) return;
    final generation = _generation;
    Uint8List? bytes;
    try {
      phase = SftpPhase.downloading;
      error = null;
      notice = null;
      progress = 0;
      _publish();
      await store.checkProfile(profile, isCurrent: () => _current(generation));
      _check(generation);
      final normalized = normalizeSftpPath(entry.path);
      bytes = await _transport!.download(
        normalized,
        maxBytes: sftpMaxTransferBytes,
        isCurrent: () => _current(generation),
        onProgress: (value) {
          if (_current(generation)) {
            progress = value;
            _publish();
          }
        },
      );
      _check(generation);
      final saved = await fileAccess.saveDownload(entry.name, bytes);
      _check(generation);
      notice = saved ? 'downloaded' : 'download_cancelled';
      phase = SftpPhase.ready;
      progress = 0;
      _publish();
    } catch (exception) {
      if (generation == _generation) {
        _end(
          code: exception is SftpFailure ? exception.code : 'transfer_failed',
        );
      }
    } finally {
      if (bytes != null) bytes.fillRange(0, bytes.length, 0);
    }
  }

  Future<void> pickAndUpload() async {
    if (phase != SftpPhase.ready) return;
    final generation = _generation;
    SftpUpload? upload;
    Uint8List? bytes;
    try {
      upload = await fileAccess.pickUpload();
      _check(generation);
      if (upload == null) return;
      if (entries.any((entry) => entry.name == upload!.name)) {
        throw const SftpFailure('already_exists');
      }
      final remotePath = joinSftpPath(path, upload.name);
      bytes = upload.bytes;
      if (bytes.length > sftpMaxTransferBytes) {
        throw const SftpFailure('file_too_large');
      }
      phase = SftpPhase.uploading;
      error = null;
      notice = null;
      progress = 0;
      _publish();
      await store.checkProfile(profile, isCurrent: () => _current(generation));
      _check(generation);
      await _transport!.upload(
        remotePath,
        bytes,
        maxBytes: sftpMaxTransferBytes,
        isCurrent: () => _current(generation),
        onProgress: (value) {
          if (_current(generation)) {
            progress = value;
            _publish();
          }
        },
      );
      _check(generation);
      notice = 'uploaded';
      phase = SftpPhase.ready;
      progress = 0;
      _publish();
    } catch (exception) {
      if (generation == _generation) {
        _end(
          code: exception is SftpFailure ? exception.code : 'transfer_failed',
        );
      }
    } finally {
      if (bytes != null) bytes.fillRange(0, bytes.length, 0);
      upload?.clear();
    }
  }

  void cancel() {
    if (!_disposed) _end();
  }

  void retire() {
    if (_retired || _disposed) return;
    _retired = true;
    _end();
  }
}
