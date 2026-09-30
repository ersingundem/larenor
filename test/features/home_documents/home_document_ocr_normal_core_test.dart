import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/home_documents/data/home_document_api.dart';
import 'package:larenor/features/home_documents/domain/home_document_models.dart';
import 'package:larenor/features/home_resources/data/core_bounded_download_api.dart';
import 'package:larenor/features/home_resources/data/core_bounded_upload_file_access.dart';
import 'package:larenor/features/home_resources/data/home_resources_api.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

void main() {
  final endpoint = Platform.environment['LARENOR_F35_CORE_URL'];
  final token = Platform.environment['LARENOR_F35_TOKEN'];
  final coreId = Platform.environment['LARENOR_F35_CORE_ID'];
  final homeId = Platform.environment['LARENOR_F35_HOME_ID'];
  final accountId = Platform.environment['LARENOR_F35_ACCOUNT_ID'];
  final resourceId = Platform.environment['LARENOR_F35_RESOURCE_ID'];
  final inventoryId = Platform.environment['LARENOR_F35_INVENTORY_ID'];
  final encodedPdf = Platform.environment['LARENOR_F35_PDF'];

  setUpAll(() => HttpOverrides.global = null);
  test(
    'Client uploads PDF and confirms real Core OCR candidate explicitly',
    () async {
      final target = ServerEndpoint(endpoint!);
      final context = ServerContext.fromJson({
        'schemaVersion': 1,
        'coreId': coreId,
        'homeId': homeId,
      });
      final transport = LarenorServerApi(endpoint: target);
      final bounded = CoreBoundedDownloadApi(
        endpoint: target,
        requestId: () => 'a' * 32,
      );
      addTearDown(transport.close);
      addTearDown(bounded.close);
      final bytes = Uint8List.fromList(base64Decode(encodedPdf!));
      final api = HomeDocumentApi(
        transport,
        token!,
        context,
        accountId!,
        isCurrent: () => true,
        uploadAdapter: CoreHomeDocumentUploadAdapter(
          resources: HomeResourcesApi(transport, token, context),
          bounded: bounded,
          files: CoreBoundedUploadFileAccess(
            pick: () async => CoreBoundedPickedFile(
              name: 'warranty.pdf',
              declaredLength: bytes.length,
              chunks: Stream.value(bytes),
            ),
          ),
          token: token,
          isCurrent: () => true,
        ),
      );
      final base = await api.search('');
      final upload = await api.pickAndUpload(
        resourceId!,
        base.authority.accountRevision,
      );
      expect(upload, isNotNull);
      expect(upload!.candidate?.provider, 'tesseract');
      expect(upload.candidate?.extractedDate, '2028-06-01');
      expect(upload.candidate?.sourceDigest, upload.blob.sha256);

      final created = await api.create(
        base: base,
        requestId: 'b' * 32,
        draft: HomeDocumentDraft(
          documentId: 'd' * 32,
          title: 'Fridge warranty',
          kind: HomeDocumentKind.warranty,
          inventoryItemId: inventoryId!,
          upload: upload,
          readerIds: const [],
          reminderLeadDays: const [30, 7],
        ),
      );
      expect(created.document.warranty.candidate?.provider, 'tesseract');
      expect(created.document.warranty.confirmedDate, isNull);
      expect((await api.reminders('2028-05-05')).items, isEmpty);

      final confirmed = await api.confirmWarranty(
        created: created,
        requestId: 'c' * 32,
        confirmedDate: '2028-06-01',
      );
      expect(confirmed.document.warranty.confirmedDate, '2028-06-01');
      expect(confirmed.document.warranty.confirmedBy, accountId);
      final exact = await api.readDocument(confirmed.document.id);
      expect(exact.document.warranty.confirmedDate, '2028-06-01');
    },
    skip:
        [
          endpoint,
          token,
          coreId,
          homeId,
          accountId,
          resourceId,
          inventoryId,
          encodedPdf,
        ].any((value) => value == null)
        ? 'Requires isolated F35 normal Core runner'
        : false,
  );
}
