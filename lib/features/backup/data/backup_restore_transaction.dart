part of 'backup_repository.dart';

const _journalV2Key = 'backup_restore_journal_v2';
Never _expiredRestore() => throw const BackupException('restore_expired', 'Read the restore preview again.');
Never _changedRestore() => throw const BackupException('restore_changed', 'The selected destination changed. Read it again.');
Never _recoveryRequired() => throw const BackupException('recovery_required', 'Restore recovery is required.');
Object? _cloneValue(Object? value) => jsonDecode(jsonEncode(value));
String _canonical(Object? value) {
  Object? sort(Object? v) => v is Map ? {for (final k in (v.keys.cast<String>().toList()..sort())) k: sort(v[k])} : v is List ? v.map(sort).toList() : v;
  return jsonEncode(sort(value));
}
String _restoreDigest(Object? value) => sha256.convert(utf8.encode(_canonical(value))).toString();
bool _same(Object? a,Object? b) => _canonical(a)==_canonical(b);
bool _mutable(bool secret,String key) => secret
  ? key == WellbeingDisclosureStore.storageKey || backupConnectionFields.values.any((v)=>v.containsValue(key))
  : backupPreferenceKeys.contains(key) || {'dashboard_layout','enabled_services_migrated'}.contains(key);
bool _directTarget(bool secret,String key) => secret
  ? key != WellbeingDisclosureStore.storageKey
  : {'dashboard_layout','enabled_services','enabled_services_migrated',DoorStation.storageKey,'movie_night_v1'}.contains(key);

class _PreparedChanges {
  _PreparedChanges(List<_Change> changes,List<String> services)
    : changes=List.unmodifiable(changes.map((c)=>_Change(c.secret,c.key,_cloneValue(c.before),_cloneValue(c.after)))),
      services=List.unmodifiable(services);
  final List<_Change> changes;
  final List<String> services;
}
class _ReadRecorder implements BackupStorage {
  _ReadRecorder(this.inner,this.current);
  final Future<void> Function() current;
  final BackupStorage inner;
  final Map<String,Object?> values = {};
  Future<Object?> read(bool secret,String key) async {
    await current();
    final id='${secret ? 's' : 'p'}:$key';
    if (_mutable(secret,key) && values.containsKey(id)) return _cloneValue(values[id]);
    final value=secret ? await inner.readSecret(key) : await inner.readPreference(key);
    await current();
    if (_mutable(secret,key)) {
      values[id]=_cloneValue(value);
      if (values.length>100 || utf8.encode(_canonical(values)).length>BackupRepository._maxJournalBytes) _recoveryRequired();
    }
    return _cloneValue(value);
  }
  @override Future<Object?> readPreference(String key)=>read(false,key);
  @override Future<String?> readSecret(String key) async => (await read(true,key)) as String?;
  @override Future<void> writePreference(String key,Object? value) async => throw StateError('Read-only restore preparation');
  @override Future<void> writeSecret(String key,String? value) async => throw StateError('Read-only restore preparation');
}

Future<PreparedBackupRestore> _prepareRestore(BackupRepository repository,BackupSnapshot snapshot,BackupSelection selection,BackupConflictPolicy conflict,BackupRestoreAccess access) async {
  try {
    // Copy synchronously before waiting for the global configuration queue.
    final frozen=BackupSnapshot.fromJson(snapshot.toJson());
    final chosen=BackupSelection(settings:selection.settings,dashboard:selection.dashboard,connections:selection.connections);
    return await ConfigurationWrites.run(() async {
      access.checkLive();
      final owner=_cloneValue(access.ownership) as Map<String,dynamic>;
      _checkRestoreOwner(owner);
      Future<void> current() async {
        access.checkLive();
        if(!_same(owner,access.ownership)) _expiredRestore();
        await access.checkDurable();
        access.checkLive();
        if(!_same(owner,access.ownership)) _expiredRestore();
      }
      await current();
      final json=frozen.toJson();
      final groups=json['groups'] as Map<String,dynamic>;
      final selected=<String,dynamic>{
        if(groups.containsKey('privacy')) 'privacy':groups['privacy'],
        if(chosen.settings && frozen.hasSettings) 'settings':groups['settings'],
        if(chosen.dashboard && frozen.hasDashboard) 'dashboard':groups['dashboard'],
        if(chosen.connections && frozen.hasConnections) 'connections':groups['connections'],
      };
      final narrowed=BackupSnapshot.fromJson({...json,'groups':selected});
      if(access.source==HomeSource.verifiedCore && (
        narrowed.hasDashboard || narrowed.hasConnections ||
        ((selected['settings'] as Map?)?.keys.any((key)=>_directTarget(false,key as String)) ?? false)
      )) throw const BackupException('restore_target_mismatch','This backup targets Direct home data.');
      final homeBearing=narrowed.hasDashboard || narrowed.hasConnections ||
          ((selected['settings'] as Map?)?.keys.any((key)=>_directTarget(false,key as String)) ?? false);
      final origin=_sourceOriginNeeded(access.source,homeBearing)
          ? await _captureHaOrigin(repository,current) : null;
      Future<void> bound() async {
        await current();
        if(origin!=null) await _verifyHaOrigin(repository,origin,current);
        await current();
      }
      final reads=_ReadRecorder(repository._storage,bound);
      final reader=BackupRepository(storage:reads,now:repository._now);
      for(final service in ((selected['connections'] as Map?)?.keys ?? const [])) {
        for(final key in backupConnectionFields[service]!.values) { await reads.readSecret(key); }
      }
      final changes=await reader._buildChanges(narrowed,chosen,conflict);
      final summary=await reader.preview(narrowed);
      await repository._requireStableConnections(changes.services);
      await current();
      final prepared=PreparedBackupRestore._(repository,access,owner,changes,reads.values,origin,summary,_restoreDigest({'snapshot':json,'selection':[chosen.settings,chosen.dashboard,chosen.connections],'conflict':conflict.name}),repository._now().toUtc().add(const Duration(minutes:5)));
      await prepared._verifyReadSet(bound);
      await bound();
      return prepared;
    });
  } on BackupException { rethrow; } catch(_) { _recoveryRequired(); }
}

/// One-use process capability. Payload/owner/read-set are private and redacted.
final class PreparedBackupRestore {
  PreparedBackupRestore._(this._repository,this._access,this._ownership,this._plan,Map<String,Object?> reads,Map<String,String?>? origin,this.summary,this._snapshotDigest,DateTime expires)
    : _haOrigin=origin==null ? null : Map.unmodifiable(origin),
      _readSet=Map.unmodifiable({...reads.map((k,v)=>MapEntry(k,_cloneValue(v))),if(origin!=null) for(final e in origin.entries) 's:${e.key}':e.value}),
      expiresAt=expires.isBefore(_access.validUntil) ? expires : _access.validUntil;
  final BackupRepository _repository;
  final BackupRestoreAccess _access;
  final Map<String,dynamic> _ownership;
  final _PreparedChanges _plan;
  final Map<String,Object?> _readSet;
  final Map<String,String?>? _haOrigin;
  final BackupPreview summary;
  final String _snapshotDigest;
  final DateTime expiresAt;
  final String _intentId=List.generate(16,(_)=>Random.secure().nextInt(256).toRadixString(16).padLeft(2,'0')).join();
  Set<String>? _recoveryIntents;
  Object? _owner;
  int _state=0;
  bool get wasHandedOff => _state>=1 && _state<=3;
  Future<void> checkBeforeHandoff() async {
    if(_state!=0) _expiredRestore();
    Future<void> current() async {
      _access.checkLive();
      await _access.checkDurable();
      _access.checkLive();
      if(!_repository._now().toUtc().isBefore(expiresAt)) _expiredRestore();
    }
    await _verifyReadSet(current);
    if(_haOrigin!=null) await _verifyHaOrigin(_repository,_haOrigin,current);
    await current();
  }
  Future<void> recoverAfterHandoff()=>ConfigurationWrites.run(() async {
    if(_state!=3) _expiredRestore();
    try {
      if(await _repository._storage.readSecret(BackupRepository.restoreJournalKey)!=null) _recoveryRequired();
      final raw=await _repository._storage.readSecret(_journalV2Key);
      final expected=_recoveryIntents;
      if(expected==null) {
        if(raw!=null) _recoveryRequired();
        return;
      }
      if(raw!=null) {
        await _recoverV2(_repository,expected:expected);
        return;
      }
      // An absent journal is never evidence for a partial rollback or commit.
      // Only a fully unchanged or fully applied result permits a fresh runtime.
      var before=true,after=true;
      for(final change in _plan.changes) {
        final value=await _readChange(_repository,change);
        before=before && _same(value,change.before);
        after=after && _same(value,change.after);
      }
      if(!before && !after) _recoveryRequired();
      for(final change in _plan.changes) {
        if(!_same(await _readChange(_repository,change),before ? change.before : change.after)) _recoveryRequired();
      }
      if(await _repository._storage.readSecret(_journalV2Key)!=null) _recoveryRequired();
    } on BackupException {rethrow;} catch(_) {_recoveryRequired();}
  });
  bool get targetsDirect => _haOrigin!=null || _plan.changes.any((c)=>_directTarget(c.secret,c.key));
  void retire() { if(_state==0) _state=4; }
  void claimForHandoff(Object owner) {
    if(_state!=0) _expiredRestore();
    _state=4;
    _access.checkLive();
    if(!_repository._now().toUtc().isBefore(expiresAt) || !_same(_ownership,_access.ownership)) _expiredRestore();
    _owner=owner; _state=1;
  }
  Future<void> _verifyReadSet(Future<void> Function() current) async {
    for(final entry in _readSet.entries) {
      await current();
      final value=entry.key.startsWith('s:') ? await _repository._storage.readSecret(entry.key.substring(2)) : await _repository._storage.readPreference(entry.key.substring(2));
      await current();
      if(!_same(value,entry.value)) _changedRestore();
    }
  }
  Future<void> applyAfterHandoff(Object owner,{required bool Function() isCurrentBoundary}) => ConfigurationWrites.run(() async {
    if(_state!=1 || !identical(owner,_owner)) _expiredRestore();
    _state=2;
    final expectedOrigin=_haOrigin==null ? null : Map<String,String?>.of(_haOrigin);
    void boundary() {
      if(!isCurrentBoundary() || !_repository._now().toUtc().isBefore(expiresAt) || !_same(_ownership,_access.ownership)) _expiredRestore();
    }
    Future<void> current() async {
      boundary();
      await _access.checkDurable();
      boundary();
      if(expectedOrigin!=null) {
        await _verifyHaOrigin(_repository,expectedOrigin,() async {boundary();});
        await _access.checkDurable();
        boundary();
      }
      await _repository._requireStableConnections(_plan.services);
      boundary();
    }
    try {
      await current();
      await _repository._requireRecovered();
      await _repository._requireStableConnections(_plan.services);
      await _verifyReadSet(current);
      await current();
      if(_plan.changes.isEmpty) return;
      final journal=_encodeV2(_repository,_plan.changes,_ownership,_snapshotDigest,_restoreDigest(_readSet),'applying',_intentId);
      final committed=_encodeV2(_repository,_plan.changes,_ownership,_snapshotDigest,_restoreDigest(_readSet),'committed',_intentId);
      _recoveryIntents=Set.unmodifiable({journal,committed});
      await _repository._storage.writeSecret(_journalV2Key,journal);
      if(await _repository._storage.readSecret(_journalV2Key)!=journal) _recoveryRequired();
      try {
        await current();
        for(final change in _plan.changes) {
          await _repository._requireStableConnections(_plan.services);
          await current();
          final before=await _readChange(_repository,change);
          await current();
          await _requireJournal(_repository,journal);
          await current();
          if(!_same(before,change.before)) _changedRestore();
          if(change.secret && expectedOrigin?.containsKey(change.key)==true) {
            expectedOrigin![change.key]=change.after as String?;
          }
          await _repository._write(change,previous:false);
          await current();
          if(!_same(await _readChange(_repository,change),change.after)) _recoveryRequired();
        }
        await _repository._requireStableConnections(_plan.services);
        await current();
        for(final change in _plan.changes) {
          final after=await _readChange(_repository,change);
          await current();
          if(!_same(after,change.after)) _recoveryRequired();
        }
        await _requireJournal(_repository,journal);
        await current();
        try { await _repository._storage.writeSecret(_journalV2Key,committed); } catch(_) {
          if(await _repository._storage.readSecret(_journalV2Key)!=committed) rethrow;
        }
        if(await _repository._storage.readSecret(_journalV2Key)!=committed) _recoveryRequired();
      } catch(_) {
        // Durable phase, not a lost response, decides rollback versus commit.
        await _recoverV2(_repository,expected:{journal,committed});
        rethrow;
      }
      await _recoverV2(_repository,expected:{committed});
    } on BackupException { rethrow; } catch(_) { _recoveryRequired(); } finally { _state=3; _owner=null; }
  });
  @override String toString()=>'PreparedBackupRestore';
}

bool _sourceOriginNeeded(HomeSource source,bool homeBearing)=>source==HomeSource.directLocal && homeBearing;
Future<Map<String,String?>> _captureHaOrigin(BackupRepository repository,Future<void> Function() current) async {
  await repository._requireStableHaConnection();await current();
  final values=<String,String?>{};
  for(final key in backupConnectionFields['ha']!.values) {
    values[key]=await repository._storage.readSecret(key);await current();
  }
  await _verifyHaOrigin(repository,values,current);
  return values;
}
Future<void> _verifyHaOrigin(BackupRepository repository,Map<String,String?> expected,Future<void> Function() current) async {
  await repository._requireStableHaConnection();await current();
  for(final entry in expected.entries) {
    final value=await repository._storage.readSecret(entry.key);await current();
    if(value!=entry.value) _changedRestore();
  }
}

void _checkRestoreOwner(Object? owner) {
  if(owner is! Map<String,dynamic> || owner.isEmpty || owner.keys.any((k)=>!{'source','scope'}.contains(k)) || !HomeSource.values.any((v)=>v.name==owner['source'])) _recoveryRequired();
  if(owner.containsKey('scope')) {
    final scope=owner['scope'];
    if(scope is! Map || scope.length!=3 || !scope.keys.toSet().containsAll({'coreId','homeId','userId'}) || scope.values.any((v)=>v is! String || v.isEmpty || v.length>128 || v.contains(RegExp(r'[\x00-\x1f\x7f]')))) _recoveryRequired();
    for(final k in ['coreId','homeId']) { if(!RegExp(r'^[a-f0-9]{32}$').hasMatch(scope[k] as String)) _recoveryRequired(); }
    if(owner['source']!='verifiedCore') _recoveryRequired();
  }
}
Future<Object?> _readChange(BackupRepository repo,_Change c)=>c.secret ? repo._storage.readSecret(c.key) : repo._storage.readPreference(c.key);
String _encodeV2(BackupRepository repo,List<_Change> changes,Map<String,dynamic> owner,String sourceDigest,String targetDigest,String phase,String intentId) {
  final value={'version':2,'intentId':intentId,'owner':owner,'sourceDigest':sourceDigest,'targetDigest':targetDigest,'phase':phase,'changes':[for(final c in changes) {'secret':c.secret,'key':c.key,'before':c.before,'after':c.after}]};
  final raw=_canonical({...value,'digest':_restoreDigest(value)});
  _decodeV2(repo,raw);
  return raw;
}
(String,List<_Change>) _decodeV2(BackupRepository repo,String raw) {
  try {
    if(utf8.encode(raw).length>BackupRepository._maxJournalBytes) _recoveryRequired();
    final data=jsonDecode(raw);
    if(data is! Map<String,dynamic> || data.length!=8 || !data.keys.toSet().containsAll({'version','intentId','owner','sourceDigest','targetDigest','phase','changes','digest'}) || data['version'] is! int || data['version']!=2 || !{'applying','committed'}.contains(data['phase'])) _recoveryRequired();
    final digest=data.remove('digest');
    if(digest!=_restoreDigest(data)) _recoveryRequired();
    for(final k in ['sourceDigest','targetDigest']) {if(data[k] is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(data[k] as String)) _recoveryRequired();}
    if(data['intentId'] is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(data['intentId'] as String)) _recoveryRequired();
    _checkRestoreOwner(data['owner']);
    final list=data['changes'];
    if(list is! List || list.isEmpty || list.length>100) _recoveryRequired();
    for(final row in list) {if(row is! Map || row.length!=4 || !row.keys.toSet().containsAll({'secret','key','before','after'})) _recoveryRequired();}
    List<_Change> decode(String side)=>repo._decodeJournal(jsonEncode({'version':1,'changes':[for(final row in list) {'secret':row['secret'],'key':row['key'],'before':row[side]}]}));
    final before=decode('before'),after=decode('after');
    final changes=[for(var i=0;i<before.length;i++) _Change(before[i].secret,before[i].key,before[i].before,after[i].before)];
    if((data['owner'] as Map)['source']=='verifiedCore' && changes.any((c)=>_directTarget(c.secret,c.key))) _recoveryRequired();
    return(data['phase'] as String,changes);
  } catch(_) { _recoveryRequired(); }
}
Future<void> _requireJournal(BackupRepository repo,String expected) async {
  if(await repo._storage.readSecret(_journalV2Key)!=expected) _recoveryRequired();
}
Future<bool> _recoverV2(BackupRepository repo,{Set<String>? expected}) async {
  try {
  final raw=await repo._storage.readSecret(_journalV2Key);
  if(expected!=null && !expected.contains(raw)) _recoveryRequired();
  if(raw==null) return false;
  final (phase,changes)=_decodeV2(repo,raw);
  for(final c in changes) {
    final now=await _readChange(repo,c);
    if(!_same(now,c.after) && (phase=='committed' || !_same(now,c.before))) _recoveryRequired();
  }
  if(phase=='applying') {
    for(final c in changes.reversed) {
      final now=await _readChange(repo,c);
      if(_same(now,c.before)) continue;
      if(!_same(now,c.after)) _recoveryRequired();
      await _requireJournal(repo,raw);
      await repo._write(c,previous:true);
      if(!_same(await _readChange(repo,c),c.before)) _recoveryRequired();
    }
  }
  for(final change in changes) {
    if(!_same(await _readChange(repo,change),phase=='applying' ? change.before : change.after)) _recoveryRequired();
  }
  await _requireJournal(repo,raw);
  try { await repo._storage.writeSecret(_journalV2Key,null); } catch(_) {
    if(await repo._storage.readSecret(_journalV2Key)!=null) rethrow;
  }
  if(await repo._storage.readSecret(_journalV2Key)!=null) _recoveryRequired();
  return true;
  } on BackupException { rethrow; } catch(_) { _recoveryRequired(); }
}
