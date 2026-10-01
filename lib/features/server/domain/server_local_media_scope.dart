import 'server_models.dart';

/// A token-free selector for this device's already verified encrypted media.
/// It never authorizes a Core request, refresh, or provider operation.
final class ServerLocalMediaScope {
  const ServerLocalMediaScope._({
    required this.coreId,
    required this.homeId,
    required this.accountId,
    required this.sessionFamilyId,
  });

  static ServerLocalMediaScope? fromSession(ServerSession? session) {
    final context = session?.context;
    final family = session?.sessionFamilyId;
    final identity = RegExp(r'^[0-9a-f]{32}$');
    if (session == null ||
        context == null ||
        family == null ||
        session.authMutationPending ||
        session.user.mustChangePassword ||
        !identity.hasMatch(session.user.id) ||
        !identity.hasMatch(family)) {
      return null;
    }
    return ServerLocalMediaScope._(
      coreId: context.coreId,
      homeId: context.homeId,
      accountId: session.user.id,
      sessionFamilyId: family,
    );
  }

  final String coreId, homeId, accountId, sessionFamilyId;

  @override
  bool operator ==(Object other) =>
      other is ServerLocalMediaScope &&
      coreId == other.coreId &&
      homeId == other.homeId &&
      accountId == other.accountId &&
      sessionFamilyId == other.sessionFamilyId;

  @override
  int get hashCode => Object.hash(coreId, homeId, accountId, sessionFamilyId);

  @override
  String toString() => 'ServerLocalMediaScope';
}
