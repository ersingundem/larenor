import 'synthetic_core_account.dart';

enum SyntheticCorePeopleView { member, empty }

/// Opt-in synthetic read fixture; RED starts with account-only behavior.
class SyntheticCorePeopleAccount extends SyntheticCoreAccount {
  SyntheticCorePeopleView view = SyntheticCorePeopleView.member;
  int peopleReads = 0;
  final requestedPeopleScopes = <(String, String)>[];
}
