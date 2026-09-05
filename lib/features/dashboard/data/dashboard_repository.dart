import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/configuration_writes.dart';
import '../../../core/home_data_scope.dart';
import '../domain/dashboard_layout.dart';
import '../domain/dashboard_layout_validation.dart';

class DashboardRepository {
  DashboardRepository({Future<SharedPreferences> Function()? loadPreferences})
    : scope = null,
      _current = null,
      _preferences = loadPreferences ?? SharedPreferences.getInstance;

  DashboardRepository.core({
    required HomeDataScope this.scope,
    required bool Function() isCurrent,
    Future<SharedPreferences> Function()? loadPreferences,
  }) : _current = isCurrent,
       _preferences = loadPreferences ?? SharedPreferences.getInstance;

  /// A non-ready Core source must fail before reading even the legacy key.
  DashboardRepository.unavailable()
    : scope = null,
      _current = _never,
      _preferences = SharedPreferences.getInstance;

  static bool _never() => false;
  final HomeDataScope? scope;
  final bool Function()? _current;
  final Future<SharedPreferences> Function() _preferences;
  String get _key => scope?.storageKey ?? 'dashboard_layout';
  static const _maxRevision = 9223372036854775806;
  static const _maxRecordBytes = maxDashboardLayoutBytes + 1024;

  void _check([bool Function()? isCurrent]) {
    if (_current?.call() == false || isCurrent?.call() == false) {
      throw const DashboardStorageException('expired');
    }
  }

  Future<SharedPreferences> _durable() async {
    _check();
    final prefs = await _preferences();
    _check();
    // Reload defeats SharedPreferences' optimistic cache after false/throwing
    // writes and also observes a backup restore before deriving another edit.
    await prefs.reload();
    _check();
    return prefs;
  }

  Future<DashboardLayout> load() async => (await readSnapshot()).layout;

  Future<DashboardSnapshot> readSnapshot() => ConfigurationWrites.run(() async {
    try {
      return _decode((await _durable()).get(_key));
    } on DashboardStorageException {
      rethrow;
    } catch (_) {
      throw const DashboardStorageException('read_failed');
    }
  });

  DashboardSnapshot _decode(Object? raw) {
    if (raw == null)
      return DashboardSnapshot._(
        scope,
        0,
        const DashboardLayout(),
        _digest('missing'),
      );
    if (raw is! String ||
        utf8.encode(raw).length >
            (scope == null ? maxDashboardLayoutBytes : _maxRecordBytes)) {
      throw const DashboardStorageException('invalid_record');
    }
    try {
      final decoded = jsonDecode(raw);
      var value = decoded;
      var revision = 0;
      if (scope != null) {
        if (decoded is! Map<String, dynamic> ||
            decoded.length != 4 ||
            !decoded.keys.toSet().containsAll({
              'version',
              'scope',
              'revision',
              'layout',
            }) ||
            decoded['version'] is! int ||
            decoded['version'] != 1 ||
            HomeDataScope.fromJson(decoded['scope']) != scope)
          throw const FormatException();
        final rev = decoded['revision'];
        if (rev is! int || rev < 1 || rev > _maxRevision)
          throw const FormatException();
        revision = rev;
        value = decoded['layout'];
      }
      validateDashboardLayoutJson(value);
      return DashboardSnapshot._(
        scope,
        revision,
        DashboardLayout.fromJson(value as Map<String, dynamic>),
        _digest(raw),
      );
    } catch (_) {
      // Corruption never becomes an empty, writable or legacy-fallback record.
      throw const DashboardStorageException('invalid_record');
    }
  }

  Future<void> save(
    DashboardLayout layout, {
    bool Function()? isCurrent,
    DashboardSnapshot? expected,
  }) {
    // Freeze and validate before entering the async queue.
    final encoded = jsonEncode(layout.toJson());
    validateDashboardLayoutJson(jsonDecode(encoded));
    return ConfigurationWrites.run(() async {
      _check(isCurrent);
      try {
        final prefs = await _durable();
        final current = _decode(prefs.get(_key));
        if (expected != null &&
            (expected.scope != scope ||
                expected.revision != current.revision ||
                expected.fingerprint != current.fingerprint)) {
          throw const DashboardStorageException('changed');
        }
        if (current.revision >= _maxRevision)
          throw const DashboardStorageException('invalid_record');
        final record = scope == null
            ? encoded
            : jsonEncode({
                'version': 1,
                'scope': scope!.toJson(),
                'revision': current.revision + 1,
                'layout': jsonDecode(encoded),
              });
        if (utf8.encode(record).length > _maxRecordBytes)
          throw const DashboardStorageException('invalid_record');
        _check(isCurrent);
        if (!await prefs.setString(_key, record))
          throw const DashboardStorageException('write_failed');
        _check(isCurrent);
      } on DashboardStorageException {
        rethrow;
      } catch (_) {
        throw const DashboardStorageException('write_failed');
      }
    });
  }
}

String _digest(String value) => sha256.convert(utf8.encode(value)).toString();

final class DashboardSnapshot {
  const DashboardSnapshot._(
    this.scope,
    this.revision,
    this.layout,
    this.fingerprint,
  );
  final HomeDataScope? scope;
  final int revision;
  final DashboardLayout layout;
  final String fingerprint;
  @override
  String toString() => 'DashboardSnapshot';
}

class DashboardStorageException implements Exception {
  const DashboardStorageException(this.code);
  final String code;
  @override
  String toString() => 'Dashboard storage unavailable';
}
