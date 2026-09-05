import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/configuration_writes.dart';
import '../domain/wellbeing_models.dart';
import 'wellbeing_store.dart';

/// Portable display restrictions, without people, accounts or measurements.
/// Restoring a vault can strengthen this policy, never silently remove it.
class WellbeingDisclosurePolicy {
  WellbeingDisclosurePolicy({
    Set<String> entityIds = const {},
    this.reviewRequired = false,
  }) : entityIds = Set.unmodifiable(entityIds);
  final Set<String> entityIds;
  final bool reviewRequired;
  Map<String, dynamic> toJson() => {
    'version': 1,
    'entityIds': entityIds.toList()..sort(),
    'reviewRequired': reviewRequired,
  };
  static WellbeingDisclosurePolicy fromJson(Object? value) {
    if (value is! Map ||
        value.length != 3 ||
        value['version'] is! int ||
        value['version'] != 1 ||
        value['reviewRequired'] is! bool ||
        value['entityIds'] is! List) {
      throw const WellbeingException(WellbeingFailure.invalidData);
    }
    final list = value['entityIds'] as List;
    if (list.length > 256 ||
        list.any((id) => id is! String || !validWellbeingEntityId(id)) ||
        list.toSet().length != list.length) {
      throw const WellbeingException(WellbeingFailure.invalidData);
    }
    return WellbeingDisclosurePolicy(
      entityIds: list.cast<String>().toSet(),
      reviewRequired: value['reviewRequired'] as bool,
    );
  }

  static WellbeingDisclosurePolicy decode(String? raw) {
    if (raw == null) return WellbeingDisclosurePolicy();
    if (raw.length > 70000) {
      throw const WellbeingException(WellbeingFailure.invalidData);
    }
    return fromJson(jsonDecode(raw));
  }
}

class WellbeingDisclosureStore {
  WellbeingDisclosureStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();
  static const storageKey = 'wellbeing_disclosure_policy_v1';
  final FlutterSecureStorage _storage;
  Future<WellbeingDisclosurePolicy> read() async {
    try {
      return WellbeingDisclosurePolicy.decode(
        await _storage.read(key: storageKey),
      );
    } catch (_) {
      throw const WellbeingException(WellbeingFailure.storageFailed);
    }
  }

  Future<void> save(
    WellbeingDisclosurePolicy policy, {
    required bool Function() isCurrent,
  }) => ConfigurationWrites.run(() async {
    if (!isCurrent()) throw const WellbeingException(WellbeingFailure.locked);
    final data = jsonEncode(
      WellbeingDisclosurePolicy.fromJson(policy.toJson()).toJson(),
    );
    if (!isCurrent()) throw const WellbeingException(WellbeingFailure.locked);
    try {
      await _storage.write(key: storageKey, value: data);
    } catch (_) {
      throw const WellbeingException(WellbeingFailure.storageFailed);
    }
  });
}

final wellbeingDisclosureStoreProvider = Provider<WellbeingDisclosureStore>(
  (_) => WellbeingDisclosureStore(),
);
final wellbeingDisclosureProvider =
    AsyncNotifierProvider<
      WellbeingDisclosureNotifier,
      WellbeingDisclosurePolicy
    >(WellbeingDisclosureNotifier.new, retry: (_, _) => null);

class WellbeingDisclosureNotifier
    extends AsyncNotifier<WellbeingDisclosurePolicy> {
  @override
  Future<WellbeingDisclosurePolicy> build() =>
      ref.watch(wellbeingDisclosureStoreProvider).read();
  Future<void> save(
    WellbeingDisclosurePolicy policy, {
    required bool Function() isCurrent,
  }) async {
    await ref
        .read(wellbeingDisclosureStoreProvider)
        .save(policy, isCurrent: () => ref.mounted && isCurrent());
    if (ref.mounted) state = AsyncData(policy);
  }
}
