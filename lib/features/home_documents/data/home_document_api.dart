import '../../home_resources/data/core_bounded_download_api.dart';
import '../../home_resources/data/core_bounded_upload_file_access.dart';
import '../../home_resources/data/home_resources_api.dart';
import '../../home_resources/domain/home_resource_models.dart';
import '../../server/data/larenor_server_api.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import 'home_document_controller.dart';
import '../domain/home_document_models.dart';

final class HomeDocumentApi implements HomeDocumentGateway {
  const HomeDocumentApi(
    this._api,
    this._token,
    this._context,
    this._accountId, {
    required this.isCurrent,
    this.uploadAdapter,
  });

  final LarenorServerApi _api;
  final String _token;
  final ServerContext _context;
  final String _accountId;
  final bool Function() isCurrent;
  final CoreHomeDocumentUploadAdapter? uploadAdapter;
  String get _root => '/home-documents/${_context.coreId}/${_context.homeId}';

  void _active() {
    if (!isCurrent()) throw const LarenorServerException('cancelled');
  }

  Future<T> _guard<T>(Future<T> Function() action) async {
    _active();
    final value = await action();
    _active();
    return value;
  }

  @override
  Future<HomeDocumentPage> search(String query) => _guard(
    () async => HomeDocumentPage.fromJson(
      await _api.request(
        'GET',
        '$_root/documents',
        token: _token,
        queryParameters: {'query': query, 'limit': '50'},
      ),
      expectedContext: _context,
      expectedAccountId: _accountId,
    ),
  );

  @override
  Future<HomeDocumentReadback> readDocument(String documentId) =>
      _guard(() async {
        if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(documentId)) {
          throw const LarenorServerException('invalid_request');
        }
        return HomeDocumentReadback.fromJson(
          await _api.request(
            'GET',
            '$_root/documents/$documentId',
            token: _token,
          ),
          expectedContext: _context,
          expectedAccountId: _accountId,
        );
      });

  @override
  Future<HomeWarrantyReminderPage> reminders(String today) => _guard(
    () async => HomeWarrantyReminderPage.fromJson(
      await _api.request(
        'GET',
        '$_root/reminders',
        token: _token,
        queryParameters: {'today': today, 'limit': '100'},
      ),
      expectedContext: _context,
      expectedAccountId: _accountId,
    ),
  );

  @override
  Future<HomeDocumentUploadEvidence?> pickAndUpload(
    String resourceId,
    int expectedAccountRevision,
  ) {
    final adapter = uploadAdapter;
    if (adapter == null) {
      throw const LarenorServerException('server_unavailable');
    }
    return _guard(
      () => adapter.pickAndUpload(
        resourceId: resourceId,
        expectedAccountRevision: expectedAccountRevision,
      ),
    );
  }

  @override
  Future<HomeDocumentCommandResult> create({
    required HomeDocumentPage base,
    required String requestId,
    required HomeDocumentDraft draft,
  }) => _guard(
    () async => HomeDocumentCommandResult.fromJson(
      await _api.request(
        'POST',
        '$_root/documents',
        token: _token,
        body: {
          'schemaVersion': 1,
          'coreId': _context.coreId,
          'homeId': _context.homeId,
          'requestId': requestId,
          'expectedAccountRevision': base.authority.accountRevision,
          'expectedRevision': base.authority.libraryRevision,
          'documentId': draft.documentId,
          'title': draft.title,
          'kind': draft.kind.name,
          'inventoryItemId': draft.inventoryItemId,
          'blob': draft.upload.blob.toJson(),
          'readerIds': draft.readerIds,
          'ocrCandidate': draft.upload.candidate?.toJson(),
          'reminderLeadDays': draft.reminderLeadDays,
        },
      ),
      expectedContext: _context,
      expectedAccountId: _accountId,
    ),
  );

  @override
  Future<HomeDocumentCommandResult> confirmWarranty({
    required HomeDocumentCommandResult created,
    required String requestId,
    required String confirmedDate,
  }) => _guard(
    () async => HomeDocumentCommandResult.fromJson(
      await _api.request(
        'POST',
        '$_root/documents/${created.document.id}/warranty',
        token: _token,
        body: {
          'schemaVersion': 1,
          'coreId': _context.coreId,
          'homeId': _context.homeId,
          'requestId': requestId,
          'expectedAccountRevision': created.authority.accountRevision,
          'expectedRevision': created.authority.libraryRevision,
          'documentId': created.document.id,
          'expectedDocumentRevision': created.document.revision,
          'confirmedDate': confirmedDate,
        },
      ),
      expectedContext: _context,
      expectedAccountId: _accountId,
    ),
  );
}

/// Reuses the Core bounded product-blob protocol. The selected resource is
/// resolved from one exact catalog snapshot before Android file bytes are read.
final class CoreHomeDocumentUploadAdapter {
  const CoreHomeDocumentUploadAdapter({
    required this.resources,
    required this.bounded,
    required this.files,
    required this.token,
    required this.isCurrent,
  });

  final HomeResourcesApi resources;
  final CoreBoundedDownloadApi bounded;
  final CoreBoundedUploadFileAccess files;
  final String token;
  final bool Function() isCurrent;

  void _active() {
    if (!isCurrent()) throw const LarenorServerException('cancelled');
  }

  Future<HomeDocumentUploadEvidence?> pickAndUpload({
    required String resourceId,
    required int expectedAccountRevision,
  }) async {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(resourceId) ||
        expectedAccountRevision < 1) {
      throw const LarenorServerException('invalid_request');
    }
    _active();
    HomeResourceRecord? target;
    String? after, snapshot;
    do {
      final page = await resources.list(
        after: after,
        snapshot: snapshot,
        limit: 100,
      );
      _active();
      if (page.userRevision != expectedAccountRevision ||
          snapshot != null && page.snapshot != snapshot) {
        throw const LarenorServerException('revision_conflict');
      }
      snapshot ??= page.snapshot;
      for (final entry in page.entries) {
        if (entry.id == resourceId) {
          if (target != null ||
              entry.kind != HomeResourceKind.resource ||
              !entry.canWrite) {
            throw const LarenorServerException('forbidden');
          }
          target = entry;
        }
      }
      after = page.nextAfter;
    } while (after != null && target == null);
    if (target == null) throw const LarenorServerException('not_found');

    final source = await files.pick();
    _active();
    if (source == null) return null;
    if (!const {
      'application/pdf',
      'image/jpeg',
      'image/png',
    }.contains(source.contentType)) {
      throw const LarenorServerException('invalid_request');
    }
    var serviceRevision = 0;
    try {
      serviceRevision = (await bounded.descriptor(
        token: token,
        target: target,
      )).serviceRevision;
    } on CoreBoundedDownloadException catch (error) {
      if (error.code != 'not_found') rethrow;
    }
    _active();
    final result = await bounded.upload(
      token: token,
      target: target,
      expectedUserRevision: expectedAccountRevision,
      expectedServiceRevision: serviceRevision,
      source: source,
    );
    _active();
    return HomeDocumentUploadEvidence(
      filename: source.filename,
      blob: HomeDocumentBlobRef.fromBounded(result.descriptor),
      candidate: null,
    );
  }
}

typedef HomeDocumentBoundedApiFactory = CoreBoundedDownloadApi Function(
  ServerEndpoint endpoint,
);

/// Route-owned account adapter. Every operation refreshes the account first,
/// then rejects endpoint, Core/home, generation, route or lifecycle drift.
final class HomeDocumentAccountGateway implements HomeDocumentGateway {
  HomeDocumentAccountGateway({
    required this.account,
    required this.context,
    required this.isCurrent,
    required this.files,
    ServerApiFactory? apiFactory,
    HomeDocumentBoundedApiFactory? boundedApiFactory,
  }) : _generation = account.generation,
       _endpoint = account.session!.endpoint,
       _api =
           (apiFactory ?? ((endpoint) => LarenorServerApi(endpoint: endpoint)))(
             account.session!.endpoint,
           ),
       _bounded =
           (boundedApiFactory ??
           ((endpoint) => CoreBoundedDownloadApi(endpoint: endpoint)))(
             account.session!.endpoint,
           );

  final ServerAccountController account;
  final ServerContext context;
  final bool Function() isCurrent;
  final CoreBoundedUploadFileAccess files;
  final int _generation;
  final ServerEndpoint _endpoint;
  final LarenorServerApi _api;
  final CoreBoundedDownloadApi _bounded;
  bool _closed = false;

  Future<HomeDocumentApi> _authorized() async {
    if (_closed || !isCurrent() || !account.isCurrent(_generation)) {
      throw const LarenorServerException('cancelled');
    }
    final session = await account.ensureSession();
    if (_closed ||
        !isCurrent() ||
        !account.isCurrent(_generation) ||
        session.context != context ||
        session.endpoint.baseUrl != _endpoint.baseUrl ||
        session.user.mustChangePassword) {
      throw const LarenorServerException('cancelled');
    }
    final resources = HomeResourcesApi(_api, session.accessToken, context);
    return HomeDocumentApi(
      _api,
      session.accessToken,
      context,
      session.user.id,
      isCurrent: isCurrent,
      uploadAdapter: CoreHomeDocumentUploadAdapter(
        resources: resources,
        bounded: _bounded,
        files: files,
        token: session.accessToken,
        isCurrent: isCurrent,
      ),
    );
  }

  @override
  Future<HomeDocumentPage> search(String query) async =>
      (await _authorized()).search(query);

  @override
  Future<HomeDocumentReadback> readDocument(String documentId) async =>
      (await _authorized()).readDocument(documentId);

  @override
  Future<HomeWarrantyReminderPage> reminders(String today) async =>
      (await _authorized()).reminders(today);

  @override
  Future<HomeDocumentUploadEvidence?> pickAndUpload(
    String resourceId,
    int expectedAccountRevision,
  ) async =>
      (await _authorized()).pickAndUpload(resourceId, expectedAccountRevision);

  @override
  Future<HomeDocumentCommandResult> create({
    required HomeDocumentPage base,
    required String requestId,
    required HomeDocumentDraft draft,
  }) async => (await _authorized()).create(
    base: base,
    requestId: requestId,
    draft: draft,
  );

  @override
  Future<HomeDocumentCommandResult> confirmWarranty({
    required HomeDocumentCommandResult created,
    required String requestId,
    required String confirmedDate,
  }) async => (await _authorized()).confirmWarranty(
    created: created,
    requestId: requestId,
    confirmedDate: confirmedDate,
  );

  void close() {
    if (_closed) return;
    _closed = true;
    _api.close();
    _bounded.close();
  }
}
