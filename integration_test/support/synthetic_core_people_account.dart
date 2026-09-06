import 'dart:convert';
import 'dart:io';

import 'home_people_contract_fixture.dart';
import 'synthetic_core_account.dart';

enum SyntheticCorePeopleView { member, empty }

/// Opt-in, read-only people protocol for disposable Android loopback tests.
/// Inherits the existing account fixture without changing any earlier journey.
/// This is not a Server authorization or persistence implementation.
class SyntheticCorePeopleAccount extends SyntheticCoreAccount {
  final Map<String, dynamic> _contract =
      jsonDecode(homePeopleContractFixture) as Map<String, dynamic>;
  SyntheticCorePeopleView view = SyntheticCorePeopleView.member;
  int peopleReads = 0;
  final requestedPeopleScopes = <(String, String)>[];

  @override
  String get userId => 'e' * 32;

  @override
  Map<String, Object?> get user => {...super.user, 'role': 'member'};

  @override
  Future<void> handle(HttpRequest request) async {
    final path = request.uri.path;
    if (!path.startsWith('/api/v1/home-people') &&
        !path.startsWith('/api/v1/admin/home-people')) {
      return super.handle(request);
    }
    final response = request.response;
    response.headers.contentType = ContentType.json;
    void error(int status, String code) {
      rejectedRequests++;
      response.statusCode = status;
      response.write(
        jsonEncode({
          'error': {'code': code},
        }),
      );
    }

    try {
      final authorization = request.headers['authorization'];
      if (logins == 0 ||
          authorization == null ||
          authorization.length != 1 ||
          authorization.single != 'Bearer $currentAccessToken') {
        error(401, 'authentication_required');
        return;
      }
      if (request.method != 'GET' || path.startsWith('/api/v1/admin/')) {
        error(403, 'forbidden');
        return;
      }
      // Only the primary member response is supplied by this fixture. Other
      // scopes have no synthetic profile authorization and never reuse it.
      if (path != '/api/v1/home-people/$coreId/$homeId' ||
          coreId != _contract['context']['coreId'] ||
          homeId != _contract['context']['homeId']) {
        error(404, 'not_found');
        return;
      }
      final query = request.uri.queryParametersAll;
      if (query.keys.any(
            (key) =>
                !const {'limit', 'after', 'expectedSnapshot'}.contains(key),
          ) ||
          query.values.any((values) => values.length != 1)) {
        error(400, 'invalid_request');
        return;
      }
      bool matches(String pattern, String value) =>
          RegExp(pattern).firstMatch(value)?.end == value.length;
      final rawLimit = query['limit']?.single ?? '25';
      final limit = int.tryParse(rawLimit);
      final after = query['after']?.single;
      final snapshot = query['expectedSnapshot']?.single;
      if (limit == null ||
          !matches(r'^[1-9][0-9]{0,2}$', rawLimit) ||
          limit > 100 ||
          after != null &&
              (!matches(r'^[0-9a-f]{32}$', after) || snapshot == null) ||
          snapshot != null && !matches(r'^[0-9a-f]{64}$', snapshot)) {
        error(400, 'invalid_request');
        return;
      }
      final name = view == SyntheticCorePeopleView.member
          ? 'memberList'
          : 'emptyMember';
      final source = jsonDecode(
        jsonEncode(_contract[name]['response']),
      ) as Map<String, dynamic>;
      if (snapshot != null && snapshot != source['snapshot']) {
        error(409, 'revision_conflict');
        return;
      }
      final entries = (source['entries'] as List).cast<Map<String, dynamic>>();
      if (after != null &&
          !entries.any((entry) => entry['ref']['id'] == after)) {
        error(404, 'not_found');
        return;
      }
      final remaining = entries
          .where(
            (entry) =>
                after == null ||
                (entry['ref']['id'] as String).compareTo(after) > 0,
          )
          .toList();
      final page = remaining.take(limit).toList();
      peopleReads++;
      requestedPeopleScopes.add((coreId, homeId));
      response.write(
        jsonEncode({
          ...source,
          'entries': page,
          'nextAfter': remaining.length > limit ? page.last['ref']['id'] : null,
        }),
      );
    } finally {
      await response.close();
    }
  }
}
