import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../../core/configuration_writes.dart';
import '../data/remote_profiles.dart';
class SshFailure implements Exception {
  const SshFailure(this.code);
  final String code;
  @override String toString() => 'SshFailure($code)';
}
enum SshCredentialKind { password, privateKey }
class SshCredential {
  const SshCredential(this.kind, this.secret, {this.passphrase = ''});
  final SshCredentialKind kind;
  final String secret, passphrase;
  @override String toString() => 'SshCredential(redacted)';
}
class SshHostPin {
  const SshHostPin(this.type, this.fingerprint);
  final String type, fingerprint;
}
class SshSecurityStore {
  SshSecurityStore({FlutterSecureStorage? storage, RemoteProfilesStore? profiles})
    : _storage=storage ?? const FlutterSecureStorage(), _profiles=profiles ?? RemoteProfilesStore();
  final FlutterSecureStorage _storage;
  final RemoteProfilesStore _profiles;
  String reference(RemoteProfile profile) => sha256.convert(utf8.encode(jsonEncode(profile.toJson()))).toString();
  void Function() _guard(bool Function() current) {
    var retired=false;
    return () {
      try {if(!retired && current()) return;} catch(_) {}
      retired=true; throw const SshFailure('retired');
    };
  }
  Future<void> _profile(RemoteProfile p,void Function() check) async {
    check();
    final snapshot=await _profiles.read(isCurrent:(){check();return true;});check();
    if(p.protocol!=RemoteProtocol.ssh || p.username.isEmpty || !snapshot.profiles.any((v)=>reference(v)==reference(p))) throw const SshFailure('profile_changed');
  }
  Future<T> _run<T>(RemoteProfile p,bool Function() current,Future<T> Function(void Function()) action) {
    final check=_guard(current);
    return ConfigurationWrites.run(() async {
      try {
        await _profile(p,check);check();
        final result=await action(check);check();
        await _profile(p,check);check();return result;
      } on SshFailure {rethrow;} on RemoteProfilesFailure catch(e) {throw SshFailure(e.code=='retired'?'retired':'profile_changed');}
      catch(_) {check();throw const SshFailure('storage_failed');}
    });
  }
  Future<Map<String,dynamic>?> _read(RemoteProfile p,String kind,void Function() check) async {
    check();final raw=await _storage.read(key:'ssh_${kind}_v1_${reference(p)}');check();
    if(raw==null) return null;
    if(raw.length>49152 || utf8.encode(raw).length>49152) throw const SshFailure('invalid_record');
    final v=jsonDecode(raw);
    if(v is! Map || v['version']!=1 || v['version'] is! int || v['target']!=reference(p)) throw const SshFailure('invalid_record');
    return Map<String,dynamic>.from(v);
  }
  Future<void> _write(RemoteProfile p,String kind,Map<String,dynamic>? value,void Function() check) async {
    final key='ssh_${kind}_v1_${reference(p)}'; final raw=value==null?null:jsonEncode({'version':1,'target':reference(p),...value});
    check();if(raw==null) {await _storage.delete(key:key);} else {await _storage.write(key:key,value:raw);}check();
    final after=await _storage.read(key:key);check();if(after!=raw) throw const SshFailure('storage_failed');
  }
  static void _credential(SshCredential v) {
    if(v.secret.isEmpty || utf8.encode(v.secret).length>(v.kind==SshCredentialKind.password?4096:32768) || v.secret.contains('\u0000') || v.passphrase.length>1024 || (v.kind==SshCredentialKind.password && v.passphrase.isNotEmpty)) throw const SshFailure('invalid_credential');
  }
  static void _pin(SshHostPin p) {
    if(!RegExp(r'^[a-zA-Z0-9@._+-]{1,80}$').hasMatch(p.type) || !RegExp(r'^SHA256:[A-Za-z0-9+/]{43}$').hasMatch(p.fingerprint)) throw const SshFailure('invalid_record');
  }
  Future<void> checkProfile(RemoteProfile p,{required bool Function() isCurrent}) => _run(p,isCurrent,(_) async {});
  Future<void> saveCredential(RemoteProfile p,SshCredential v,{required bool Function() isCurrent}) => _run(p,isCurrent,(check) async {
    _credential(v);
    // A corrupt old record must be explicitly forgotten before replacement.
    final old=await _read(p,'credential',check);if(old!=null) _decodeCredential(old);
    await _write(p,'credential',{'kind':v.kind.name,'secret':v.secret,'passphrase':v.passphrase},check);
  });
  SshCredential _decodeCredential(Map<String,dynamic> v) {
    if(v.length!=5 || !SshCredentialKind.values.any((k)=>k.name==v['kind']) || v['secret'] is! String || v['passphrase'] is! String) throw const SshFailure('invalid_record');
    final c=SshCredential(SshCredentialKind.values.byName(v['kind']),v['secret'],passphrase:v['passphrase']);_credential(c);return c;
  }
  Future<SshCredential?> readCredential(RemoteProfile p,{required bool Function() isCurrent}) => _run(p,isCurrent,(check) async {
    final v=await _read(p,'credential',check);return v==null?null:_decodeCredential(v);
  });
  Future<void> forgetCredential(RemoteProfile p,{required bool Function() isCurrent}) => _run(p,isCurrent,(check)=>_write(p,'credential',null,check));
  SshHostPin _decodePin(Map<String,dynamic> v) {
    if(v.length!=4 || v['type'] is! String || v['fingerprint'] is! String) throw const SshFailure('invalid_record');
    final p=SshHostPin(v['type'],v['fingerprint']);_pin(p);return p;
  }
  Future<SshHostPin?> readPin(RemoteProfile p,{required bool Function() isCurrent}) => _run(p,isCurrent,(check) async {
    final v=await _read(p,'pin',check);return v==null?null:_decodePin(v);
  });
  Future<void> trust(RemoteProfile p,SshHostPin pin,{required bool Function() isCurrent}) => _run(p,isCurrent,(check) async {
    _pin(pin);final v=await _read(p,'pin',check);
    if(v!=null) {final old=_decodePin(v);if(old.type!=pin.type || old.fingerprint!=pin.fingerprint) throw const SshFailure('host_changed');return;}
    await _write(p,'pin',{'type':pin.type,'fingerprint':pin.fingerprint},check);
  });
}
