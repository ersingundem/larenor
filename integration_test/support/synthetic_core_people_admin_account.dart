import 'dart:async';
import 'synthetic_core_account.dart';

/// Explicit, disposable admin-person protocol; never production authorization.
class SyntheticCorePeopleAdminAccount extends SyntheticCoreAccount {
  int peopleReads=0,usersReads=0,grantReads=0;
  String role='admin';
  @override String get userId=>'f'*32;
  @override Map<String,Object?> get user=>{...super.user,'role':role};
  List<Map<String,dynamic>> get records=>[];
  List<String> get mutations=>[];
  Completer<void>? bodyStarted,replyGate;
  void retireSession(){}
}
