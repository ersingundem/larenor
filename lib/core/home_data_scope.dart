import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Storage ownership only. A scope never establishes account authority.
final class HomeDataScope {
  const HomeDataScope._(this.coreId, this.homeId, this.userId);

  factory HomeDataScope.fromJson(Object? value) {
    const invalid = FormatException('Invalid home data scope');
    if (value is! Map<String, dynamic> ||
        value.length != 3 ||
        !value.keys.toSet().containsAll({'coreId', 'homeId', 'userId'})) {
      throw invalid;
    }
    String identity(Object? input) {
      if (input is! String ||
          input.length != 32 ||
          !RegExp(r'^[a-f0-9]{32}$').hasMatch(input))
        throw invalid;
      return input;
    }

    final user = value['userId'];
    if (user is! String ||
        user.isEmpty ||
        user.length > 128 ||
        user.contains(RegExp(r'[\x00-\x1f\x7f]')))
      throw invalid;
    return HomeDataScope._(
      identity(value['coreId']),
      identity(value['homeId']),
      user,
    );
  }

  final String coreId, homeId, userId;

  String get storageKey =>
      'dashboard_layout_core_v1_${sha256.convert(utf8.encode(jsonEncode(['core-layout-v1', coreId, homeId, userId])))}';
  Map<String, dynamic> toJson() => {
    'coreId': coreId,
    'homeId': homeId,
    'userId': userId,
  };

  @override
  bool operator ==(Object other) =>
      other is HomeDataScope &&
      coreId == other.coreId &&
      homeId == other.homeId &&
      userId == other.userId;
  @override
  int get hashCode => Object.hash(coreId, homeId, userId);
  @override
  String toString() => 'HomeDataScope';
}
