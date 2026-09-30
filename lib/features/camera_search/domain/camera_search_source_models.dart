import '../../server/domain/server_models.dart';

final class CameraSearchSourceChoice {
  const CameraSearchSourceChoice(this.id, this.name, this.revision);
  final String id, name;
  final int? revision;
}

final class CameraSearchSourceState {
  const CameraSearchSourceState(
    this.revision,
    this.services,
    this.cameras,
    this.serviceId,
    this.cameraIds,
  );
  final int revision;
  final List<CameraSearchSourceChoice> services, cameras;
  final String? serviceId;
  final List<String> cameraIds;

  static CameraSearchSourceState decode(Map<String, dynamic> raw) {
    Never invalid() => throw const LarenorServerException('invalid_response');
    bool identity(Object? value) =>
        value is String && RegExp(r'^[0-9a-f]{32}$').hasMatch(value);
    bool revision(Object? value, {bool zero = false}) =>
        value is int && value >= (zero ? 0 : 1) && value < 0x7fffffffffffffff;
    if (raw.length != 5 ||
        !raw.keys.every(
          {
            'schemaVersion',
            'revision',
            'settings',
            'services',
            'cameras',
          }.contains,
        ) ||
        raw['schemaVersion'] != 1 ||
        !revision(raw['revision'], zero: true)) {
      invalid();
    }
    List<CameraSearchSourceChoice> choices(Object? value, bool service) {
      if (value is! List || value.length > (service ? 128 : 512)) invalid();
      final ids = <String>{};
      final result = <CameraSearchSourceChoice>[];
      for (final item in value) {
        if (item is! Map<String, dynamic> ||
            item.length != (service ? 3 : 2) ||
            !item.keys.every(
              {'id', 'name', if (service) 'revision'}.contains,
            ) ||
            !identity(item['id']) ||
            !ids.add(item['id'] as String) ||
            item['name'] is! String ||
            (item['name'] as String).trim().isEmpty ||
            (item['name'] as String).length > 120 ||
            (item['name'] as String).contains(
              RegExp(r'[\x00-\x1f\x7f-\x9f]'),
            ) ||
            service && !revision(item['revision'])) {
          invalid();
        }
        result.add(
          CameraSearchSourceChoice(
            item['id'] as String,
            item['name'] as String,
            service ? item['revision'] as int : null,
          ),
        );
      }
      return List.unmodifiable(result);
    }

    final saved = raw['settings'];
    final cameraIds = <String>[];
    String? serviceId;
    if (saved != null) {
      if (saved is! Map<String, dynamic> ||
          saved.length != 5 ||
          !saved.keys.every(
            {
              'schemaVersion',
              'expectedRevision',
              'serviceId',
              'expectedServiceRevision',
              'cameraResourceIds',
            }.contains,
          ) ||
          saved['schemaVersion'] != 1 ||
          !revision(saved['expectedRevision'], zero: true) ||
          saved['expectedRevision'] != (raw['revision'] as int) - 1 ||
          !identity(saved['serviceId']) ||
          !revision(saved['expectedServiceRevision']) ||
          saved['cameraResourceIds'] is! List) {
        invalid();
      }
      final values = saved['cameraResourceIds'] as List;
      if (values.isEmpty ||
          values.length > 16 ||
          values.any((value) => !identity(value)) ||
          values.toSet().length != values.length) {
        invalid();
      }
      serviceId = saved['serviceId'] as String;
      cameraIds.addAll(values.cast<String>());
    }
    if ((raw['revision'] == 0) != (saved == null)) invalid();
    return CameraSearchSourceState(
      raw['revision'] as int,
      choices(raw['services'], true),
      choices(raw['cameras'], false),
      serviceId,
      List.unmodifiable(cameraIds),
    );
  }
}
