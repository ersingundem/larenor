part of 'keenetic_client.dart';

extension KeeneticTelemetryReader on KeeneticClient {
  /// Only fixed show commands. Selection values are JSON parameters and must
  /// match inventory returned during this same read, never command fragments.
  Future<KeeneticTelemetrySnapshot> readTelemetry(
    KeeneticTelemetryDemand demand, {
    Object? accountGeneration,
    bool includeMetadata = true,
  }) async {
    _checkActive();
    final generation = _requestGeneration;
    final identity = accountGeneration ?? this;
    var resources = const KeeneticReading<KeeneticRouterStatus>();
    var internet = const KeeneticReading<KeeneticInternetStatus>();
    var interfaces = const KeeneticReading<List<KeeneticInterface>>();
    var hosts = const KeeneticReading<KeeneticHostSummary>();
    final traffic = <String, KeeneticReading<KeeneticTrafficSample>>{};
    final keys = <String>[];
    final commands = <Map<String, dynamic>>[];
    void add(String key, Map<String, dynamic> command) {
      keys.add(key);
      commands.add(command);
    }

    if (includeMetadata &&
        demand.kinds.contains(KeeneticMetricKind.routerResources)) {
      add('version', {'version': {}});
      add('system', {'system': {}});
    }
    if (demand.kinds.contains(KeeneticMetricKind.interfaces) ||
        demand.kinds.contains(KeeneticMetricKind.wanTraffic)) {
      // A current inventory read authorizes each selected interface on every
      // traffic cycle, including failover/replacement and background resume.
      add('interface', {'interface': {}});
    }
    if (includeMetadata &&
        demand.kinds.contains(KeeneticMetricKind.internetStatus)) {
      add('internet', {
        'internet': {'status': {}},
      });
    }
    if (includeMetadata &&
        demand.kinds.contains(KeeneticMetricKind.connectedDevices)) {
      add('ip', {
        'ip': {'hotspot': {}},
      });
    }
    final payloads = <String, Object?>{};
    final failures = <String, KeeneticReadFailure>{};
    if (commands.isNotEmpty) {
      try {
        final result = await _request('/rci/show', body: commands);
        _checkActive(generation);
        if (result is! List || result.length != keys.length) throw _invalid();
        for (var i = 0; i < keys.length; i++) {
          try {
            final envelope = _object(result[i]);
            if (!envelope.containsKey(keys[i])) throw _invalid();
            var value = envelope[keys[i]];
            if (keys[i] == 'internet') value = _object(value)['status'];
            if (keys[i] == 'ip') value = _object(value)['hotspot'];
            _checkCommandResult(value);
            payloads[keys[i]] = value;
          } on KeeneticApiException catch (error) {
            failures[keys[i]] = error.failure;
          }
        }
      } on KeeneticApiException catch (error) {
        if (error.failure == KeeneticReadFailure.inactive) rethrow;
        for (final key in keys) {
          failures[key] = error.failure;
        }
      }
    }
    KeeneticReading<T> parse<T>(String key, T Function(Object?) decode) {
      if (!keys.contains(key)) return const KeeneticReading();
      if (failures[key] case final issue?) return KeeneticReading(issue: issue);
      try {
        return KeeneticReading(value: decode(payloads[key]), readAt: _now());
      } catch (_) {
        return const KeeneticReading(
          issue: KeeneticReadFailure.invalidResponse,
        );
      }
    }

    if (keys.contains('system')) {
      final version = parse('version', _object);
      final system = parse('system', _object);
      final issue = system.issue ?? version.issue;
      final status = KeeneticRouterStatus.fromJson(
        version.value ?? {},
        system.value ?? {},
      );
      final usable =
          status.cpuPercent != null ||
          status.memoryTotalKiB != null ||
          status.uptimeSeconds != null ||
          status.firmware != null ||
          status.model != 'Keenetic';
      resources = KeeneticReading(
        value: usable ? status : null,
        readAt: usable ? _now() : null,
        issue: issue ?? (usable ? null : KeeneticReadFailure.invalidResponse),
      );
    }
    interfaces = parse('interface', _parseInterfaces);
    internet = parse('internet', (value) {
      final result = KeeneticInternetStatus.fromJson(_object(value));
      if (!result.hasEvidence) throw _invalid();
      return result;
    });
    hosts = parse(
      'ip',
      (value) => KeeneticHostSummary.fromJson(_list(value, 'host')),
    );
    if (demand.kinds.contains(KeeneticMetricKind.wanTraffic)) {
      final known = {
        for (final item in interfaces.value ?? <KeeneticInterface>[]) item.id,
      };
      final selected = demand.interfaceIds.toList()..sort();
      final eligible = <String>[];
      for (final id in selected) {
        if (eligible.length < 4 && interfaces.succeeded && known.contains(id)) {
          eligible.add(id);
        } else {
          traffic[id] = KeeneticReading(
            issue: interfaces.issue ?? KeeneticReadFailure.selectionRequired,
          );
        }
      }
      if (eligible.isNotEmpty) {
        try {
          final decoded = _object(
            await _request(
              '/rci/show',
              body: {
                'interface': [
                  for (final id in eligible) {'name': id, 'stat': {}},
                ],
              },
            ),
          );
          _checkActive(generation);
          final entries = decoded['interface'];
          if (entries is! List || entries.length != eligible.length) {
            throw _invalid();
          }
          for (var i = 0; i < eligible.length; i++) {
            final id = eligible[i];
            try {
              final entry = _object(entries[i]);
              // Some versions return only the requested command envelope. If
              // identity is included it must agree; never accept another ID.
              if ((entry['name'] != null && entry['name'] != id) ||
                  (entry['id'] != null && entry['id'] != id)) {
                throw _invalid();
              }
              final values = _object(entry['stat']);
              _checkCommandResult(values);
              final sample = KeeneticTrafficSample.fromJson(id, values);
              if (sample.receivedBytes == null && sample.sentBytes == null) {
                throw _invalid();
              }
              traffic[id] = KeeneticReading(value: sample, readAt: _now());
            } on KeeneticApiException catch (error) {
              traffic[id] = KeeneticReading(issue: error.failure);
            }
          }
        } on KeeneticApiException catch (error) {
          if (error.failure == KeeneticReadFailure.inactive) rethrow;
          for (final id in eligible) {
            traffic[id] = KeeneticReading(issue: error.failure);
          }
        }
      }
    }
    _checkActive(generation);
    final readings = <KeeneticReading<Object>>[
      resources,
      internet,
      interfaces,
      hosts,
      ...traffic.values,
    ];
    if (readings.any((value) => value.value != null)) {
      healthSession?.readSucceeded();
    }
    // A successful sibling does not erase an incomplete/denied source.
    final issues = readings
        .map((value) => value.issue)
        .whereType<KeeneticReadFailure>()
        .toList();
    issues.sort((a, b) => _failurePriority(b).compareTo(_failurePriority(a)));
    if (issues.isNotEmpty) _report(issues.first);
    return KeeneticTelemetrySnapshot(
      accountGeneration: identity,
      resources: resources,
      internet: internet,
      interfaces: interfaces,
      hosts: hosts,
      traffic: traffic,
    );
  }

  List<KeeneticInterface> _parseInterfaces(Object? decoded) {
    final List<Map<String, dynamic>> rows;
    if (decoded is Map<String, dynamic> && decoded['interface'] is List) {
      rows = _list(decoded, 'interface');
    } else if (decoded is Map<String, dynamic>) {
      rows = [];
      for (final entry in decoded.entries) {
        if (entry.value is! Map<String, dynamic>) continue;
        final item = entry.value as Map<String, dynamic>;
        if (item['id'] != null && item['id'] != entry.key) throw _invalid();
        rows.add({...item, 'id': entry.key});
      }
      if (decoded.isNotEmpty && rows.isEmpty) throw _invalid();
    } else {
      rows = _list(decoded, 'interface');
    }
    if (rows.length > 1024) throw _invalid();
    final result = rows.map(KeeneticInterface.fromJson).toList();
    if (result.map((item) => item.id).toSet().length != result.length) {
      throw _invalid();
    }
    return List.unmodifiable(result);
  }
}

int _failurePriority(KeeneticReadFailure failure) => switch (failure) {
  KeeneticReadFailure.authentication => 10,
  KeeneticReadFailure.permission => 9,
  KeeneticReadFailure.transport || KeeneticReadFailure.timeout => 8,
  KeeneticReadFailure.server || KeeneticReadFailure.rejected => 7,
  KeeneticReadFailure.invalidResponse => 6,
  KeeneticReadFailure.unsupported => 5,
  _ => 0,
};
