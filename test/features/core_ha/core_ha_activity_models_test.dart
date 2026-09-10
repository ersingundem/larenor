import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/core_ha/domain/core_ha_activity_models.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import 'package:larenor/features/home_resources/domain/home_resource_models.dart';

HomeResourceRecord historyTarget() {
  final contract = jsonDecode(
    File('contracts/home-assistant.v1.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final context = ServerContext.fromJson(contract['context']);
  return HomeResourceRecord.fromJson(
    contract['resource'],
    expectedContext: context,
  );
}

Map<String, dynamic> historyContract() => jsonDecode(
  File('contracts/home-assistant-history.v1.json').readAsStringSync(),
) as Map<String, dynamic>;

Map<String, dynamic> verificationJson({bool compared = false}) => {
  'schemaVersion': 1,
  'scope': {
    'schemaVersion': 1,
    'coreId': historyTarget().context.coreId,
    'homeId': historyTarget().context.homeId,
  },
  'chainId': 'a' * 32,
  'sequence': 2,
  'headHash': 'b' * 64,
  'checkpoint': 'eyJjaGFpbiI6InN5bnRoZXRpYyJ9.fixture',
  'verified': true,
  'comparedCheckpoint': compared,
  'causalityVerified': false,
};

Matcher failure([String code = 'invalid_response']) => throwsA(
  isA<LarenorServerException>().having((error) => error.code, 'code', code),
);

void main() {
  test('strict history model retains attribution and observed result', () {
    final response = historyContract()['complete']['response'];
    final page = CoreHaHistoryPage.fromJson(response, target: historyTarget());
    expect(page.entries, hasLength(2));
    final first = page.entries.first;
    expect(first.attribution.source, CoreHaAttributionSource.coreApi);
    expect(first.attribution.reason, CoreHaAttributionReason.explicitCommand);
    expect(first.attribution.correlationId, first.receipt.requestId);
    expect(first.receipt.actorId, 'f' * 32);
    expect(first.receipt.providerAccepted, isTrue);
    expect(first.receipt.observationMatchesTarget, isTrue);
    expect(page.nextBefore, isNull);
  });

  test('history rejects forged attribution, order, cursor and extra data', () {
    final original = jsonDecode(
      jsonEncode(historyContract()['complete']['response']),
    ) as Map<String, dynamic>;
    final entries = original['entries'] as List<dynamic>;
    final first = entries.first as Map<String, dynamic>;
    final second = entries.last as Map<String, dynamic>;
    final mutations = <void Function(Map<String, dynamic>)>[
      (value) =>
          ((value['entries'] as List).first['attribution']
                  as Map<String, dynamic>)['correlationId'] =
              '7' * 32,
      (value) => (value['entries'] as List).setAll(0, [second, first]),
      (value) => value['nextBefore'] = '7' * 32,
      (value) => value['private'] = 'must not be accepted',
    ];
    for (final mutate in mutations) {
      final value = jsonDecode(jsonEncode(original)) as Map<String, dynamic>;
      mutate(value);
      expect(
        () => CoreHaHistoryPage.fromJson(value, target: historyTarget()),
        failure(),
      );
    }
  });

  test('verification binds scope and distinguishes external comparison', () {
    final current = CoreHaHistoryVerification.fromJson(
      verificationJson(),
      expectedContext: historyTarget().context,
      expectedComparison: false,
    );
    expect(current.verified, isTrue);
    expect(current.comparedCheckpoint, isFalse);
    expect(current.sequence, 2);
    final compared = CoreHaHistoryVerification.fromJson(
      verificationJson(compared: true),
      expectedContext: historyTarget().context,
      expectedComparison: true,
    );
    expect(compared.comparedCheckpoint, isTrue);
  });

  test('verification fails closed on scope, proof and comparison mismatch', () {
    final mutations = <void Function(Map<String, dynamic>)>[
      (value) => (value['scope'] as Map<String, dynamic>)['homeId'] = 'f' * 32,
      (value) => value['verified'] = false,
      (value) => value['causalityVerified'] = true,
      (value) => value['headHash'] = 'b' * 63,
      (value) => value['checkpoint'] = 'x' * 513,
    ];
    for (final mutate in mutations) {
      final value = verificationJson();
      mutate(value);
      expect(
        () => CoreHaHistoryVerification.fromJson(
          value,
          expectedContext: historyTarget().context,
          expectedComparison: false,
        ),
        failure(),
      );
    }
    expect(
      () => CoreHaHistoryVerification.fromJson(
        verificationJson(compared: true),
        expectedContext: historyTarget().context,
        expectedComparison: false,
      ),
      failure(),
    );
  });
}
