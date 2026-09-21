import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/home_documents/domain/home_document_models.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import 'home_document_fixture.dart';

void main() {
  test('document page binds exact private Core authority', () {
    final context = ServerContext.fromJson({
      'schemaVersion': 1,
      'coreId': core,
      'homeId': home,
    });
    final page = HomeDocumentPage.fromJson(
      homeDocumentPageFixture(),
      expectedContext: context,
      expectedAccountId: account,
    );
    expect(page.items.single.title, 'Buzdolabı faturası');
    expect(page.items.single.warranty.confirmedDate, isNull);
    expect(page.authority.libraryRevision, 1);
  });

  test('foreign, duplicate and incoherent private projections fail closed', () {
    final base = homeDocumentPageFixture();
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (value) =>
          (value['authority'] as Map<String, dynamic>)['homeId'] = 'f' * 32,
      (value) => (value['items'] as List).add(
        Map<String, dynamic>.from((value['items'] as List).first as Map),
      ),
      (value) =>
          ((value['items'] as List).first as Map<String, dynamic>)['revision'] =
              2,
      (value) =>
          ((((value['items'] as List).first as Map<String, dynamic>)['warranty']
                  as Map<String, dynamic>))['correctedFromOcr'] =
              true,
    ]) {
      final bad = jsonDecode(jsonEncode(base)) as Map<String, dynamic>;
      mutate(bad);
      expect(
        () => HomeDocumentPage.fromJson(
          bad,
          expectedContext: context(),
          expectedAccountId: account,
        ),
        throwsA(isA<LarenorServerException>()),
      );
    }
  });
}
