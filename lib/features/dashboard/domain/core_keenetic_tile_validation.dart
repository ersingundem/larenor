const _fields = {
  'coreId',
  'coreHomeId',
  'coreResourceId',
  'coreResourceRevision',
  'coreResourceAclRevision',
  'coreBindingId',
  'coreBindingRevision',
};

/// A Core card is a capability reference, never a router credential or URL.
bool hasValidCoreKeeneticTileFields(Map<String, dynamic> tile) {
  final present = _fields.where((field) => tile[field] != null).length;
  const types = {
    'coreKeenetic',
    'coreKeeneticDetails',
    'coreKeeneticMesh',
    'coreKeeneticClients',
    'coreKeeneticBandwidth',
  };
  if (!types.contains(tile['type'])) return present == 0;
  if (present != _fields.length ||
      tile['entityId'] != null ||
      tile['url'] != null ||
      tile['keeneticMetric'] != null ||
      tile['keeneticInterfaceId'] != null ||
      tile['webPanel'] != null) {
    return false;
  }
  bool identity(Object? value) =>
      value is String && RegExp(r'^[0-9a-f]{32}$').hasMatch(value);
  bool revision(Object? value) =>
      value is int && value >= 1 && value <= 0x7fffffffffffffff;
  return identity(tile['coreId']) &&
      identity(tile['coreHomeId']) &&
      identity(tile['coreResourceId']) &&
      revision(tile['coreResourceRevision']) &&
      revision(tile['coreResourceAclRevision']) &&
      identity(tile['coreBindingId']) &&
      revision(tile['coreBindingRevision']);
}
