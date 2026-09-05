import 'dart:convert';

import 'home_resource_contract_fixture.dart';

enum SyntheticCoreResourceView { member, revoked, empty }

/// Opt-in, read-only responses for a disposable loopback Core fixture.
/// These public records come from the real Server contract, not home services.
class SyntheticCoreResources {
  final Map<String, dynamic> _contract =
      jsonDecode(homeResourceContractFixture) as Map<String, dynamic>;
  SyntheticCoreResourceView view = SyntheticCoreResourceView.member;
  int reads = 0;
  final requestedScopes = <(String, String)>[];

  (int, Map<String, dynamic>) list(
    String coreId,
    String homeId,
    Map<String, List<String>> query,
  ) {
    (int, Map<String, dynamic>) error(int status, String code) => (
      status,
      {
        'error': {'code': code},
      },
    );
    const keys = {'limit', 'after', 'expectedSnapshot'};
    if (query.keys.any((key) => !keys.contains(key)) ||
        query.values.any((values) => values.length != 1)) {
      return error(400, 'invalid_request');
    }
    String? value(String key) => query[key]?.single;
    final rawLimit = value('limit') ?? '25';
    final limit = int.tryParse(rawLimit);
    final after = value('after');
    final snapshot = value('expectedSnapshot');
    if (limit == null ||
        !RegExp(r'^[1-9][0-9]{0,2}$').hasMatch(rawLimit) ||
        limit > 100 ||
        (after != null &&
            (!RegExp(r'^[0-9a-f]{32}$').hasMatch(after) || snapshot == null)) ||
        (snapshot != null && !RegExp(r'^[0-9a-f]{64}$').hasMatch(snapshot))) {
      return error(400, 'invalid_request');
    }
    final String name;
    if (coreId == 'a' * 32 && homeId == 'b' * 32) {
      name = switch (view) {
        SyntheticCoreResourceView.member => 'memberList',
        SyntheticCoreResourceView.revoked => 'revokedList',
        SyntheticCoreResourceView.empty => 'emptyList',
      };
    } else if (coreId == 'c' * 32 && homeId == 'd' * 32) {
      name = 'otherContextList';
    } else {
      return error(404, 'not_found');
    }
    // Clone at the fixture boundary so test callers cannot mutate our source.
    final source =
        jsonDecode(jsonEncode(_contract[name])) as Map<String, dynamic>;
    if (snapshot != null && snapshot != source['snapshot']) {
      return error(409, 'revision_conflict');
    }
    final entries = (source['entries'] as List).cast<Map<String, dynamic>>();
    if (after != null && !entries.any((entry) => entry['ref']['id'] == after)) {
      return error(404, 'not_found');
    }
    final remaining = entries
        .where(
          (entry) =>
              after == null ||
              (entry['ref']['id'] as String).compareTo(after) > 0,
        )
        .toList();
    final page = remaining.take(limit).toList();
    reads++;
    requestedScopes.add((coreId, homeId));
    return (
      200,
      {
        ...source,
        'entries': page,
        'nextAfter': remaining.length > limit ? page.last['ref']['id'] : null,
      },
    );
  }
}
