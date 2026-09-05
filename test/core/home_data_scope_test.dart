import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/home_data_scope.dart';

Map<String, Object?> value() => {
  'coreId': 'a' * 32,
  'homeId': 'b' * 32,
  'userId': 'user-one',
};

void main() {
  test('scope has stable canonical namespace without addresses or secrets', () {
    final a = HomeDataScope.fromJson(value());
    final b = HomeDataScope.fromJson({
      'userId': 'user-one',
      'homeId': 'b' * 32,
      'coreId': 'a' * 32,
    });
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(
      a.storageKey,
      matches(RegExp(r'^dashboard_layout_core_v1_[a-f0-9]{64}$')),
    );
    expect(a.toString(), 'HomeDataScope');
    a.toJson()['userId'] = 'changed';
    expect(a, b);
    for (final key in ['coreId', 'homeId', 'userId']) {
      final other = {...value(), key: key == 'userId' ? 'user-two' : 'c' * 32};
      expect(HomeDataScope.fromJson(other).storageKey, isNot(a.storageKey));
    }
  });
  for (final invalid in <Object?>[
    null,
    [],
    {...value(), 'unknown': 1},
    {...value()}..remove('userId'),
    {...value(), 'coreId': 'A' * 32},
    {...value(), 'coreId': 'a' * 31},
    {...value(), 'coreId': '${'a' * 31}\n'},
    {...value(), 'homeId': 1},
    {...value(), 'homeId': 'f' * 33},
    {...value(), 'userId': ''},
    {...value(), 'userId': 'u' * 129},
    {...value(), 'userId': 'user\u0000two'},
    {...value(), 'userId': 'user\u007ftwo'},
  ].indexed) {
    test('scope rejects malformed identity ${invalid.$1}', () {
      expect(
        () => HomeDataScope.fromJson(invalid.$2),
        throwsA(isA<FormatException>()),
      );
    });
  }
}
