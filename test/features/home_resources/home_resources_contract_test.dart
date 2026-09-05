import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import 'home_resources_fixture.dart' show contract;

void main() {
  final fixture = contract();
  final context = ServerContext.fromJson(fixture['context']);
  for (final key in ['emptyList', 'adminList', 'memberList', 'revokedList']) {
    test('actual authenticated Server contract $key', () {
      final page = HomeResourcePage.fromJson(
        fixture[key],
        expectedContext: context,
      );
      expect(page.entries.length, (fixture[key]['entries'] as List).length);
    });
  }
  test('actual one-record pages and Unicode maximum remain valid', () {
    final first = HomeResourcePage.fromJson(
      fixture['firstPage'],
      expectedContext: context, limit: 1,
    );
    final second = HomeResourcePage.fromJson(
      fixture['secondPage'],
      expectedContext: context, limit: 1,
      after: first.nextAfter,
      expectedSnapshot: first.snapshot,
    );
    expect(first.entries, hasLength(1));
    expect(second.entries, hasLength(1));
    expect(
      HomeResourceRecord.fromJson(
        fixture['record']['record'],
        expectedContext: context,
      ).label,
      'Salon',
    );
    expect(
      HomeResourceRecord.fromJson(
        fixture['unicodeRecord']['record'],
        expectedContext: context,
      ).label.runes.length,
      80,
    );
    expect(
      () => HomeResourcePage.fromJson(
        fixture['otherContextList'],
        expectedContext: context,
      ),
      throwsA(isA<LarenorServerException>()),
    );
  });
}
