import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/home_documents/data/home_document_api.dart';
import 'package:larenor/features/home_documents/domain/home_document_models.dart';
import 'package:larenor/features/home_resources/data/core_bounded_download_api.dart';
import 'package:larenor/features/home_resources/data/core_bounded_upload_file_access.dart';
import 'package:larenor/features/home_resources/data/home_resources_api.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import 'home_document_fixture.dart';

http.Response _json(Object? value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  test('HTTP contract binds reads and mutations to exact authority', () async {
    final steps = <({String method, String path, Object? body, Object response})>[
      (
        method: 'GET',
        path: '/api/v1/home-documents/$core/$home/documents?query=&limit=50',
        body: null,
        response: homeDocumentPageFixture(empty: true, revision: 0),
      ),
      (
        method: 'GET',
        path: '/api/v1/home-documents/$core/$home/reminders?today=2028-05-05&limit=100',
        body: null,
        response: reminderPageFixture(revision: 0),
      ),
      (
        method: 'POST',
        path: '/api/v1/home-documents/$core/$home/documents',
        body: isA<Map<String, Object?>>(),
        response: {
          'authority': authority(1),
          'document': documentJson(),
          'replayed': false,
        },
      ),
      (
        method: 'POST',
        path: '/api/v1/home-documents/$core/$home/documents/$document/warranty',
        body: isA<Map<String, Object?>>(),
        response: {
          'authority': authority(2),
          'document': documentJson(
            revision: 2,
            confirmedDate: '2028-06-01',
          ),
          'replayed': false,
        },
      ),
    ];
    var index = 0;
    final transport = LarenorServerApi(
      endpoint: ServerEndpoint('https://synthetic.invalid'),
      client: MockClient((request) async {
        final step = steps[index++];
        expect(request.method, step.method);
        expect(request.url.toString(), 'https://synthetic.invalid${step.path}');
        expect(request.headers['authorization'], 'Bearer synthetic_token');
        if (step.body != null) {
          expect(jsonDecode(request.body), step.body);
        }
        return _json(step.response, step.method == 'POST' && index == 3 ? 201 : 200);
      }),
    );
    addTearDown(transport.close);
    final api = HomeDocumentApi(
      transport,
      'synthetic_token',
      context(),
      account,
      isCurrent: () => true,
    );
    final base = await api.search('');
    expect((await api.reminders('2028-05-05')).items, isEmpty);
    final created = await api.create(
      base: base,
      requestId: 'b' * 32,
      draft: HomeDocumentDraft(
        documentId: document,
        title: 'Buzdolabı faturası',
        kind: HomeDocumentKind.invoice,
        inventoryItemId: inventory,
        upload: upload(),
        readerIds: ['a' * 32],
        reminderLeadDays: [30, 7],
      ),
    );
    expect(created.authority.libraryRevision, 1);
    final confirmed = await api.confirmWarranty(
      created: created,
      requestId: 'c' * 32,
      confirmedDate: '2028-06-01',
    );
    expect(confirmed.document.warranty.correctedFromOcr, isTrue);
    expect(index, 4);
  });

  test('bounded adapter verifies exact writable target and upload receipt', () async {
    final bytes = Uint8List.fromList(utf8.encode('%PDF synthetic'));
    final digest = sha256.convert(bytes).toString();
    final resourceTransport = LarenorServerApi(
      endpoint: ServerEndpoint('https://synthetic.invalid'),
      client: MockClient((request) async => _json({
        'scope': context().toJson(),
        'userRevision': 5,
        'entries': [
          {
            'ref': {
              'schemaVersion': 1,
              'coreId': core,
              'homeId': home,
              'kind': 'resource',
              'id': blobId,
            },
            'label': 'Warranty document slot',
            'order': 0,
            'revision': 2,
            'aclRevision': 3,
            'permissions': {'read': true, 'write': true},
          },
        ],
        'snapshot': 'f' * 64,
        'nextAfter': null,
      })),
    );
    addTearDown(resourceTransport.close);
    var calls = 0;
    final bounded = CoreBoundedDownloadApi(
      endpoint: ServerEndpoint('https://synthetic.invalid'),
      requestId: () => 'a' * 32,
      client: MockClient((request) async {
        calls++;
        if (request.method == 'GET') return _json(null, 404);
        expect(request.method, 'PUT');
        expect(request.headers['x-larenor-expected-user-revision'], '5');
        expect(request.headers['x-larenor-expected-resource-revision'], '2');
        expect(request.headers['x-larenor-expected-acl-revision'], '3');
        expect(request.headers['x-larenor-expected-service-revision'], '0');
        expect(request.bodyBytes, bytes);
        return _json({
          'blob': {
            'requestId': 'a' * 32,
            'resourceId': blobId,
            'serviceRevision': 1,
            'contentLength': bytes.length,
            'sha256': digest,
            'contentType': 'application/pdf',
            'createdAt': 1800000000.0,
            'updatedAt': 1800000000.0,
          },
        }, 201);
      }),
    );
    addTearDown(bounded.close);
    final adapter = CoreHomeDocumentUploadAdapter(
      resources: HomeResourcesApi(
        resourceTransport,
        'synthetic_token',
        context(),
      ),
      bounded: bounded,
      files: CoreBoundedUploadFileAccess(
        pick: () async => CoreBoundedPickedFile(
          name: 'warranty.pdf',
          declaredLength: bytes.length,
          chunks: Stream.value(bytes),
        ),
      ),
      token: 'synthetic_token',
      isCurrent: () => true,
    );
    final result = await adapter.pickAndUpload(
      resourceId: blobId,
      expectedAccountRevision: 5,
    );
    expect(result!.filename, 'warranty.pdf');
    expect(result.blob.sha256, digest);
    expect(result.candidate, isNull);
    expect(calls, 2);
  });
}

