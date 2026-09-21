import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/home_documents/data/home_document_controller.dart';
import 'package:larenor/features/home_documents/domain/home_document_models.dart';

import 'home_document_fixture.dart';

final class _Gateway implements HomeDocumentGateway {
  final searches = <Future<HomeDocumentPage>>[];
  final due = <Future<HomeWarrantyReminderPage>>[];
  Future<HomeDocumentUploadEvidence?>? uploadResult;
  HomeDocumentCommandResult? createResult, confirmResult;
  int searchIndex = 0,
      dueIndex = 0,
      uploadCalls = 0,
      createCalls = 0,
      confirmCalls = 0;
  String? confirmedDate;

  @override
  Future<HomeDocumentPage> search(String query) => searches[searchIndex++];
  @override
  Future<HomeWarrantyReminderPage> reminders(String today) => due[dueIndex++];
  @override
  Future<HomeDocumentUploadEvidence?> pickAndUpload(
    String resourceId,
    int expectedAccountRevision,
  ) {
    expect(resourceId, blobId);
    expect(expectedAccountRevision, 5);
    uploadCalls++;
    return uploadResult!;
  }

  @override
  Future<HomeDocumentCommandResult> create({
    required HomeDocumentPage base,
    required String requestId,
    required HomeDocumentDraft draft,
  }) async {
    createCalls++;
    expect(draft.readerIds, ['a' * 32]);
    expect(draft.upload.candidate?.extractedDate, '2028-05-10');
    return createResult!;
  }

  @override
  Future<HomeDocumentCommandResult> confirmWarranty({
    required HomeDocumentCommandResult created,
    required String requestId,
    required String confirmedDate,
  }) async {
    confirmCalls++;
    this.confirmedDate = confirmedDate;
    return confirmResult!;
  }
}

HomeDocumentController _controller(
  _Gateway gateway, {
  bool admin = true,
  bool Function()? current,
}) => HomeDocumentController(
  gateway: gateway,
  context: context(),
  accountId: account,
  isAdmin: admin,
  isCurrent: current ?? () => true,
  requestIdFactory: () => 'b' * 32,
  documentIdFactory: () => document,
  today: () => DateTime(2028, 5, 5),
);

void main() {
  test(
    'OCR suggestion requires explicit corrected admin confirmation',
    () async {
      final gateway = _Gateway()
        ..searches.addAll([
          Future.value(page(empty: true, revision: 0)),
          Future.value(
            page(revision: 2, documentRevision: 2, confirmedDate: '2028-06-01'),
          ),
        ])
        ..due.addAll([
          Future.value(reminders(revision: 0)),
          Future.value(reminders(revision: 2, confirmedDate: '2028-06-01')),
        ])
        ..uploadResult = Future.value(upload())
        ..createResult = result(revision: 1)
        ..confirmResult = result(
          revision: 2,
          documentRevision: 2,
          confirmedDate: '2028-06-01',
        );
      final controller = _controller(gateway);
      addTearDown(controller.dispose);
      await controller.load();
      await controller.stageUpload(blobId);
      expect(controller.upload?.candidate?.extractedDate, '2028-05-10');
      expect(gateway.createCalls, 0);
      await controller.publish(
        title: 'Buzdolabı faturası',
        kind: HomeDocumentKind.invoice,
        inventoryItemId: inventory,
        readerIds: ['a' * 32],
        confirmWarranty: true,
        warrantyDate: '2028-06-01',
      );
      expect(gateway.createCalls, 1);
      expect(gateway.confirmCalls, 1);
      expect(gateway.confirmedDate, '2028-06-01');
      expect(controller.page?.items.single.warranty.correctedFromOcr, isTrue);
      expect(controller.reminderPage?.items.single.expiresOn, '2028-06-01');
    },
  );

  test('member cannot start upload or publish', () async {
    final gateway = _Gateway()
      ..searches.add(Future.value(page()))
      ..due.add(Future.value(reminders()));
    final controller = _controller(gateway, admin: false);
    addTearDown(controller.dispose);
    await controller.load();
    await controller.stageUpload(blobId);
    expect(gateway.uploadCalls, 0);
    expect(controller.canUpload, isFalse);
    expect(controller.page?.items.length, 1);
  });

  test('route and lifecycle authority reject late private results', () async {
    final delayed = Completer<HomeDocumentPage>();
    final gateway = _Gateway()
      ..searches.add(delayed.future)
      ..due.add(Future.value(reminders()));
    var current = true;
    final controller = _controller(gateway, current: () => current);
    addTearDown(controller.dispose);
    final pending = controller.load();
    current = false;
    controller.setActive(false);
    delayed.complete(page());
    await pending;
    expect(controller.page, isNull);
    expect(controller.upload, isNull);
    expect(controller.failure, HomeDocumentFailure.stale);
  });
}
