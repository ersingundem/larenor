import '../../home_resources/data/core_bounded_download_api.dart';
import '../../server/domain/server_models.dart';

Never _invalid([String code = 'invalid_response']) =>
    throw LarenorServerException(code);

Map<Object?, Object?> _object(Object? raw, Set<String> keys) {
  if (raw is! Map ||
      raw.length != keys.length ||
      !keys.every(raw.containsKey)) {
    _invalid();
  }
  return raw;
}

String _hex(Object? value, [int length = 32]) {
  if (value is! String || !RegExp('^[0-9a-f]{$length}\$').hasMatch(value)) {
    _invalid();
  }
  return value;
}

int _revision(Object? value, {bool empty = false}) {
  if (value is! int || value < (empty ? 0 : 1) || value > 9223372036854775807) {
    _invalid();
  }
  return value;
}

String _date(Object? value, {bool optional = false}) {
  if (optional && value == null) return '';
  if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    _invalid();
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null ||
      '${parsed.year.toString().padLeft(4, '0')}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')}' !=
          value) {
    _invalid();
  }
  return value;
}

String _text(Object? value, int max) {
  if (value is! String ||
      value.isEmpty ||
      value != value.trim() ||
      value.runes.length > max ||
      value.runes.any(
        (rune) => rune < 32 || rune == 127 || rune >= 0xd800 && rune <= 0xdfff,
      )) {
    _invalid();
  }
  return value;
}

double _timestamp(Object? value) {
  final parsed = value is num ? value.toDouble() : double.nan;
  if (!parsed.isFinite || parsed < 0 || parsed > 8640000000000) _invalid();
  return parsed;
}

enum HomeDocumentKind { invoice, manual, warranty, other }

final class HomeDocumentAuthority {
  const HomeDocumentAuthority._({
    required this.context,
    required this.accountId,
    required this.sessionFamilyId,
    required this.accountRevision,
    required this.libraryRevision,
  });

  factory HomeDocumentAuthority.fromJson(
    Object? raw, {
    required ServerContext expectedContext,
    required String expectedAccountId,
  }) {
    final value = _object(raw, {
      'schemaVersion',
      'coreId',
      'homeId',
      'accountId',
      'sessionFamilyId',
      'accountRevision',
      'libraryRevision',
    });
    final context = ServerContext.fromJson({
      'schemaVersion': value['schemaVersion'],
      'coreId': value['coreId'],
      'homeId': value['homeId'],
    });
    final accountId = _hex(value['accountId']);
    if (context != expectedContext || accountId != expectedAccountId) {
      _invalid();
    }
    return HomeDocumentAuthority._(
      context: context,
      accountId: accountId,
      sessionFamilyId: _hex(value['sessionFamilyId']),
      accountRevision: _revision(value['accountRevision']),
      libraryRevision: _revision(value['libraryRevision'], empty: true),
    );
  }

  final ServerContext context;
  final String accountId, sessionFamilyId;
  final int accountRevision, libraryRevision;

  bool sameSession(HomeDocumentAuthority other) =>
      context == other.context &&
      accountId == other.accountId &&
      sessionFamilyId == other.sessionFamilyId &&
      accountRevision == other.accountRevision;
}

final class HomeDocumentBlobRef {
  const HomeDocumentBlobRef._({
    required this.resourceId,
    required this.serviceRevision,
    required this.contentLength,
    required this.sha256,
    required this.contentType,
  });

  factory HomeDocumentBlobRef.fromJson(Object? raw) {
    final value = _object(raw, {
      'schemaVersion',
      'resourceId',
      'serviceRevision',
      'contentLength',
      'sha256',
      'contentType',
    });
    final contentType = value['contentType'];
    final length = value['contentLength'];
    if (value['schemaVersion'] != 1 ||
        !const {
          'application/pdf',
          'image/jpeg',
          'image/png',
        }.contains(contentType) ||
        length is! int ||
        length < 1 ||
        length > CoreBoundedDownloadApi.maxBlobBytes) {
      _invalid();
    }
    return HomeDocumentBlobRef._(
      resourceId: _hex(value['resourceId']),
      serviceRevision: _revision(value['serviceRevision']),
      contentLength: length,
      sha256: _hex(value['sha256'], 64),
      contentType: contentType as String,
    );
  }

  factory HomeDocumentBlobRef.fromBounded(CoreBoundedBlobDescriptor value) =>
      HomeDocumentBlobRef.fromJson({
        'schemaVersion': 1,
        'resourceId': value.resourceId,
        'serviceRevision': value.serviceRevision,
        'contentLength': value.contentLength,
        'sha256': value.sha256,
        'contentType': value.contentType,
      });

  final String resourceId, sha256, contentType;
  final int serviceRevision, contentLength;

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'resourceId': resourceId,
    'serviceRevision': serviceRevision,
    'contentLength': contentLength,
    'sha256': sha256,
    'contentType': contentType,
  };
}

final class HomeDocumentOcrCandidate {
  const HomeDocumentOcrCandidate._({
    required this.extractedDate,
    required this.confidencePermille,
    required this.sourceRevision,
    required this.sourceDigest,
  });
  factory HomeDocumentOcrCandidate.fromJson(Object? raw) {
    final value = _object(raw, {
      'schemaVersion',
      'extractedDate',
      'confidencePermille',
      'sourceRevision',
      'sourceDigest',
    });
    final confidence = value['confidencePermille'];
    if (value['schemaVersion'] != 1 ||
        confidence is! int ||
        confidence < 0 ||
        confidence > 1000) {
      _invalid();
    }
    return HomeDocumentOcrCandidate._(
      extractedDate: _date(value['extractedDate']),
      confidencePermille: confidence,
      sourceRevision: _revision(value['sourceRevision']),
      sourceDigest: _hex(value['sourceDigest'], 64),
    );
  }
  final String extractedDate, sourceDigest;
  final int confidencePermille, sourceRevision;

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'extractedDate': extractedDate,
    'confidencePermille': confidencePermille,
    'sourceRevision': sourceRevision,
    'sourceDigest': sourceDigest,
  };
}

final class HomeDocumentWarranty {
  const HomeDocumentWarranty._({
    required this.candidate,
    required this.confirmedDate,
    required this.confirmedBy,
    required this.confirmedAt,
    required this.correctedFromOcr,
  });
  factory HomeDocumentWarranty.fromJson(Object? raw) {
    final value = _object(raw, {
      'candidate',
      'confirmedDate',
      'confirmedBy',
      'confirmedAt',
      'correctedFromOcr',
    });
    final candidate = value['candidate'] == null
        ? null
        : HomeDocumentOcrCandidate.fromJson(value['candidate']);
    final confirmed = value['confirmedDate'] == null
        ? null
        : _date(value['confirmedDate']);
    final confirmedBy = value['confirmedBy'] == null
        ? null
        : _hex(value['confirmedBy']);
    final confirmedAt = value['confirmedAt'] == null
        ? null
        : _timestamp(value['confirmedAt']);
    final corrected = value['correctedFromOcr'];
    if (corrected is! bool ||
        (confirmed == null) != (confirmedBy == null) ||
        (confirmed == null) != (confirmedAt == null) ||
        confirmed == null && corrected ||
        confirmed != null &&
            corrected !=
                (candidate != null && candidate.extractedDate != confirmed)) {
      _invalid();
    }
    return HomeDocumentWarranty._(
      candidate: candidate,
      confirmedDate: confirmed,
      confirmedBy: confirmedBy,
      confirmedAt: confirmedAt,
      correctedFromOcr: corrected,
    );
  }
  final HomeDocumentOcrCandidate? candidate;
  final String? confirmedDate, confirmedBy;
  final double? confirmedAt;
  final bool correctedFromOcr;
}

final class HomeDocument {
  const HomeDocument._({
    required this.id,
    required this.context,
    required this.revision,
    required this.title,
    required this.kind,
    required this.inventoryItemId,
    required this.blob,
    required this.warranty,
    required this.createdAt,
    required this.updatedAt,
  });
  factory HomeDocument.fromJson(Object? raw, ServerContext expected) {
    final value = _object(raw, {
      'schemaVersion',
      'ref',
      'revision',
      'title',
      'kind',
      'inventoryItemId',
      'blob',
      'warranty',
      'createdAt',
      'updatedAt',
    });
    final ref = _object(value['ref'], {
      'schemaVersion',
      'coreId',
      'homeId',
      'kind',
      'id',
    });
    final context = ServerContext.fromJson({
      'schemaVersion': ref['schemaVersion'],
      'coreId': ref['coreId'],
      'homeId': ref['homeId'],
    });
    final kind = switch (value['kind']) {
      'invoice' => HomeDocumentKind.invoice,
      'manual' => HomeDocumentKind.manual,
      'warranty' => HomeDocumentKind.warranty,
      'other' => HomeDocumentKind.other,
      _ => _invalid(),
    };
    final created = _timestamp(value['createdAt']);
    final updated = _timestamp(value['updatedAt']);
    if (value['schemaVersion'] != 1 ||
        ref['kind'] != 'home_document' ||
        context != expected ||
        updated < created) {
      _invalid();
    }
    return HomeDocument._(
      id: _hex(ref['id']),
      context: context,
      revision: _revision(value['revision']),
      title: _text(value['title'], 120),
      kind: kind,
      inventoryItemId: _hex(value['inventoryItemId']),
      blob: HomeDocumentBlobRef.fromJson(value['blob']),
      warranty: HomeDocumentWarranty.fromJson(value['warranty']),
      createdAt: created,
      updatedAt: updated,
    );
  }
  final String id, title, inventoryItemId;
  final ServerContext context;
  final int revision;
  final HomeDocumentKind kind;
  final HomeDocumentBlobRef blob;
  final HomeDocumentWarranty warranty;
  final double createdAt, updatedAt;
}

final class HomeDocumentPage {
  const HomeDocumentPage._(this.authority, this.items, this.hasMore);
  factory HomeDocumentPage.fromJson(
    Object? raw, {
    required ServerContext expectedContext,
    required String expectedAccountId,
  }) {
    final value = _object(raw, {
      'schemaVersion',
      'authority',
      'items',
      'hasMore',
    });
    final source = value['items'];
    if (value['schemaVersion'] != 1 ||
        source is! List ||
        source.length > 50 ||
        value['hasMore'] is! bool) {
      _invalid();
    }
    final authority = HomeDocumentAuthority.fromJson(
      value['authority'],
      expectedContext: expectedContext,
      expectedAccountId: expectedAccountId,
    );
    final items = source
        .map((item) => HomeDocument.fromJson(item, expectedContext))
        .toList(growable: false);
    final ordered = [...items]
      ..sort((a, b) {
        final title = a.title.toLowerCase().compareTo(b.title.toLowerCase());
        return title == 0 ? a.id.compareTo(b.id) : title;
      });
    if (items.map((item) => item.id).toSet().length != items.length ||
        items.indexed.any((entry) => !identical(entry.$2, ordered[entry.$1])) ||
        items.any((item) => item.revision > authority.libraryRevision)) {
      _invalid();
    }
    return HomeDocumentPage._(
      authority,
      List.unmodifiable(items),
      value['hasMore'] as bool,
    );
  }
  final HomeDocumentAuthority authority;
  final List<HomeDocument> items;
  final bool hasMore;
}

final class HomeDocumentReadback {
  const HomeDocumentReadback._(this.authority, this.document);

  factory HomeDocumentReadback.fromJson(
    Object? raw, {
    required ServerContext expectedContext,
    required String expectedAccountId,
  }) {
    final value = _object(raw, {'schemaVersion', 'authority', 'document'});
    if (value['schemaVersion'] != 1) _invalid();
    final authority = HomeDocumentAuthority.fromJson(
      value['authority'],
      expectedContext: expectedContext,
      expectedAccountId: expectedAccountId,
    );
    final document = HomeDocument.fromJson(value['document'], expectedContext);
    if (document.revision > authority.libraryRevision) _invalid();
    return HomeDocumentReadback._(authority, document);
  }

  final HomeDocumentAuthority authority;
  final HomeDocument document;
}

final class HomeWarrantyReminder {
  const HomeWarrantyReminder._({
    required this.documentId,
    required this.inventoryItemId,
    required this.title,
    required this.remindOn,
    required this.expiresOn,
  });
  factory HomeWarrantyReminder.fromJson(Object? raw) {
    final value = _object(raw, {
      'schemaVersion',
      'documentId',
      'inventoryItemId',
      'title',
      'remindOn',
      'expiresOn',
    });
    if (value['schemaVersion'] != 1) _invalid();
    return HomeWarrantyReminder._(
      documentId: _hex(value['documentId']),
      inventoryItemId: _hex(value['inventoryItemId']),
      title: _text(value['title'], 120),
      remindOn: _date(value['remindOn']),
      expiresOn: _date(value['expiresOn']),
    );
  }
  final String documentId, inventoryItemId, title, remindOn, expiresOn;
}

final class HomeWarrantyReminderPage {
  const HomeWarrantyReminderPage._(this.authority, this.items, this.hasMore);
  factory HomeWarrantyReminderPage.fromJson(
    Object? raw, {
    required ServerContext expectedContext,
    required String expectedAccountId,
  }) {
    final value = _object(raw, {
      'schemaVersion',
      'authority',
      'items',
      'hasMore',
    });
    final source = value['items'];
    if (value['schemaVersion'] != 1 ||
        source is! List ||
        source.length > 100 ||
        value['hasMore'] is! bool) {
      _invalid();
    }
    final authority = HomeDocumentAuthority.fromJson(
      value['authority'],
      expectedContext: expectedContext,
      expectedAccountId: expectedAccountId,
    );
    final items = source
        .map(HomeWarrantyReminder.fromJson)
        .toList(growable: false);
    final ordered = [...items]
      ..sort((a, b) {
        final expiry = a.expiresOn.compareTo(b.expiresOn);
        return expiry == 0 ? a.documentId.compareTo(b.documentId) : expiry;
      });
    if (items.map((item) => item.documentId).toSet().length != items.length ||
        items.indexed.any((entry) => !identical(entry.$2, ordered[entry.$1])) ||
        items.isNotEmpty && authority.libraryRevision == 0) {
      _invalid();
    }
    return HomeWarrantyReminderPage._(
      authority,
      List.unmodifiable(items),
      value['hasMore'] as bool,
    );
  }
  final HomeDocumentAuthority authority;
  final List<HomeWarrantyReminder> items;
  final bool hasMore;
}

final class HomeDocumentUploadEvidence {
  const HomeDocumentUploadEvidence({
    required this.filename,
    required this.blob,
    required this.candidate,
  });
  final String filename;
  final HomeDocumentBlobRef blob;
  final HomeDocumentOcrCandidate? candidate;
}

final class HomeDocumentReader {
  const HomeDocumentReader({required this.id, required this.label});
  final String id, label;
}

final class HomeDocumentDraft {
  factory HomeDocumentDraft({
    required String documentId,
    required String title,
    required HomeDocumentKind kind,
    required String inventoryItemId,
    required HomeDocumentUploadEvidence upload,
    required List<String> readerIds,
    required List<int> reminderLeadDays,
  }) {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(documentId) ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(inventoryItemId) ||
        title.isEmpty ||
        title != title.trim() ||
        title.runes.length > 120 ||
        title.runes.any(
          (rune) =>
              rune < 32 || rune == 127 || rune >= 0xd800 && rune <= 0xdfff,
        ) ||
        readerIds.length > 64 ||
        readerIds.toSet().length != readerIds.length ||
        readerIds.any((id) => !RegExp(r'^[0-9a-f]{32}$').hasMatch(id)) ||
        reminderLeadDays.length > 8 ||
        reminderLeadDays.toSet().length != reminderLeadDays.length ||
        reminderLeadDays.any((days) => days < 0 || days > 365)) {
      _invalid('invalid_request');
    }
    return HomeDocumentDraft._(
      documentId,
      title,
      kind,
      inventoryItemId,
      upload,
      List.unmodifiable(readerIds),
      List.unmodifiable(reminderLeadDays),
    );
  }
  const HomeDocumentDraft._(
    this.documentId,
    this.title,
    this.kind,
    this.inventoryItemId,
    this.upload,
    this.readerIds,
    this.reminderLeadDays,
  );
  final String documentId, title, inventoryItemId;
  final HomeDocumentKind kind;
  final HomeDocumentUploadEvidence upload;
  final List<String> readerIds;
  final List<int> reminderLeadDays;
}

final class HomeDocumentCommandResult {
  const HomeDocumentCommandResult._(
    this.authority,
    this.document,
    this.replayed,
  );
  factory HomeDocumentCommandResult.fromJson(
    Object? raw, {
    required ServerContext expectedContext,
    required String expectedAccountId,
  }) {
    final value = _object(raw, {'authority', 'document', 'replayed'});
    if (value['replayed'] is! bool) _invalid();
    final authority = HomeDocumentAuthority.fromJson(
      value['authority'],
      expectedContext: expectedContext,
      expectedAccountId: expectedAccountId,
    );
    final document = HomeDocument.fromJson(value['document'], expectedContext);
    if (document.revision > authority.libraryRevision) _invalid();
    return HomeDocumentCommandResult._(
      authority,
      document,
      value['replayed'] as bool,
    );
  }
  final HomeDocumentAuthority authority;
  final HomeDocument document;
  final bool replayed;
}
