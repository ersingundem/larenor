import 'package:larenor/features/home_documents/domain/home_document_models.dart';
import 'package:larenor/features/server/domain/server_models.dart';

final core = '1' * 32;
final home = '2' * 32;
final account = '3' * 32;
final family = '4' * 32;
final document = '5' * 32;
final inventory = '6' * 32;
final blobId = '7' * 32;

ServerContext context() => ServerContext.fromJson({
  'schemaVersion': 1,
  'coreId': core,
  'homeId': home,
});

Map<String, Object?> authority(
  int revision, {
  String? accountId,
  String? familyId,
}) => {
  'schemaVersion': 1,
  'coreId': core,
  'homeId': home,
  'accountId': accountId ?? account,
  'sessionFamilyId': familyId ?? family,
  'accountRevision': 5,
  'libraryRevision': revision,
};

Map<String, Object?> documentJson({
  int revision = 1,
  String? confirmedDate,
}) => {
  'schemaVersion': 1,
  'ref': {
    'schemaVersion': 1,
    'coreId': core,
    'homeId': home,
    'kind': 'home_document',
    'id': document,
  },
  'revision': revision,
  'title': 'Buzdolabı faturası',
  'kind': 'invoice',
  'inventoryItemId': inventory,
  'blob': {
    'schemaVersion': 1,
    'resourceId': blobId,
    'serviceRevision': 3,
    'contentLength': 1024,
    'sha256': '8' * 64,
    'contentType': 'application/pdf',
  },
  'warranty': {
    'candidate': {
      'schemaVersion': 1,
      'extractedDate': '2028-05-10',
      'confidencePermille': 810,
      'sourceRevision': 12,
      'sourceDigest': '9' * 64,
    },
    'confirmedDate': confirmedDate,
    'confirmedBy': confirmedDate == null ? null : account,
    'confirmedAt': confirmedDate == null ? null : 1800000100.0,
    'correctedFromOcr': confirmedDate != null && confirmedDate != '2028-05-10',
  },
  'createdAt': 1800000000.0,
  'updatedAt': confirmedDate == null ? 1800000000.0 : 1800000100.0,
};

Map<String, Object?> homeDocumentPageFixture({
  int revision = 1,
  int documentRevision = 1,
  String? confirmedDate,
  bool empty = false,
  bool hasMore = false,
  String? accountId,
  String? familyId,
}) => {
  'schemaVersion': 1,
  'authority': authority(revision, accountId: accountId, familyId: familyId),
  'items': empty
      ? []
      : [
          documentJson(
            revision: documentRevision,
            confirmedDate: confirmedDate,
          ),
        ],
  'hasMore': hasMore,
};

Map<String, Object?> reminderPageFixture({
  int revision = 1,
  String? confirmedDate,
  String? accountId,
  String? familyId,
}) => {
  'schemaVersion': 1,
  'authority': authority(revision, accountId: accountId, familyId: familyId),
  'items': confirmedDate == null
      ? []
      : [
          {
            'schemaVersion': 1,
            'documentId': document,
            'inventoryItemId': inventory,
            'title': 'Buzdolabı faturası',
            'remindOn': '2028-05-02',
            'expiresOn': confirmedDate,
          },
        ],
  'hasMore': false,
};

HomeDocumentPage page({
  int revision = 1,
  int documentRevision = 1,
  String? confirmedDate,
  bool empty = false,
  bool hasMore = false,
}) => HomeDocumentPage.fromJson(
  homeDocumentPageFixture(
    revision: revision,
    documentRevision: documentRevision,
    confirmedDate: confirmedDate,
    empty: empty,
    hasMore: hasMore,
  ),
  expectedContext: context(),
  expectedAccountId: account,
);

HomeDocumentReadback readback({
  int revision = 1,
  int documentRevision = 1,
  String? confirmedDate,
}) => HomeDocumentReadback.fromJson(
  {
    'schemaVersion': 1,
    'authority': authority(revision),
    'document': documentJson(
      revision: documentRevision,
      confirmedDate: confirmedDate,
    ),
  },
  expectedContext: context(),
  expectedAccountId: account,
);

HomeWarrantyReminderPage reminders({int revision = 1, String? confirmedDate}) =>
    HomeWarrantyReminderPage.fromJson(
      reminderPageFixture(revision: revision, confirmedDate: confirmedDate),
      expectedContext: context(),
      expectedAccountId: account,
    );

HomeDocumentCommandResult result({
  int revision = 1,
  int documentRevision = 1,
  String? confirmedDate,
}) => HomeDocumentCommandResult.fromJson(
  {
    'authority': authority(revision),
    'document': documentJson(
      revision: documentRevision,
      confirmedDate: confirmedDate,
    ),
    'replayed': false,
  },
  expectedContext: context(),
  expectedAccountId: account,
);

HomeDocumentUploadEvidence upload() {
  final item = page().items.single;
  return HomeDocumentUploadEvidence(
    filename: 'fatura.pdf',
    blob: item.blob,
    candidate: item.warranty.candidate,
  );
}
