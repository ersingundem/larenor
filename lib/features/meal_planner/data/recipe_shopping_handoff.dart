import '../../../core/home_session_controller.dart';
import '../../../core/home_source_store.dart';
import '../../server/domain/server_models.dart';
import '../../today/data/today_actions.dart';
import '../../today/domain/today_models.dart';
import '../domain/recipe_shopping_draft.dart';

enum RecipeShoppingAuthorityKind { core, deviceLocal }

final class RecipeShoppingAuthorityFacts {
  const RecipeShoppingAuthorityFacts._({
    required this.kind,
    required this.coreId,
    required this.homeId,
    required this.accountId,
    required this.sessionFamily,
    required this.endpointBaseUrl,
    required this.runtimeIdentity,
    required this.interactionEpoch,
  });

  factory RecipeShoppingAuthorityFacts.core({
    required String coreId,
    required String homeId,
    required String accountId,
    required int sessionFamily,
    required String endpointBaseUrl,
    required Object runtimeIdentity,
    required int interactionEpoch,
  }) => RecipeShoppingAuthorityFacts._(
    kind: RecipeShoppingAuthorityKind.core,
    coreId: _identity(coreId),
    homeId: _identity(homeId),
    accountId: _account(accountId),
    sessionFamily: _family(sessionFamily),
    endpointBaseUrl: ServerEndpoint(endpointBaseUrl).baseUrl,
    runtimeIdentity: runtimeIdentity,
    interactionEpoch: interactionEpoch,
  );

  factory RecipeShoppingAuthorityFacts.deviceLocal({
    required Object runtimeIdentity,
    required int interactionEpoch,
  }) => RecipeShoppingAuthorityFacts._(
    kind: RecipeShoppingAuthorityKind.deviceLocal,
    coreId: null,
    homeId: null,
    accountId: null,
    sessionFamily: null,
    endpointBaseUrl: null,
    runtimeIdentity: runtimeIdentity,
    interactionEpoch: interactionEpoch,
  );

  final RecipeShoppingAuthorityKind kind;
  final String? coreId, homeId, accountId, endpointBaseUrl;
  final int? sessionFamily;
  final Object runtimeIdentity;
  final int interactionEpoch;

  RecipeShoppingAuthorityFacts copyWith({
    String? coreId,
    String? homeId,
    String? accountId,
    int? sessionFamily,
    String? endpointBaseUrl,
    Object? runtimeIdentity,
    int? interactionEpoch,
  }) => RecipeShoppingAuthorityFacts._(
    kind: kind,
    coreId: coreId ?? this.coreId,
    homeId: homeId ?? this.homeId,
    accountId: accountId ?? this.accountId,
    sessionFamily: sessionFamily ?? this.sessionFamily,
    endpointBaseUrl: endpointBaseUrl ?? this.endpointBaseUrl,
    runtimeIdentity: runtimeIdentity ?? this.runtimeIdentity,
    interactionEpoch: interactionEpoch ?? this.interactionEpoch,
  );

  static String _identity(String value) {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
      throw const RecipeShoppingException('invalid_authority');
    }
    return value;
  }

  static String _account(String value) {
    if (value.isEmpty ||
        value.length > 128 ||
        value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw const RecipeShoppingException('invalid_authority');
    }
    return value;
  }

  static int _family(int value) {
    if (value < 0 || value > 0x7fffffff) {
      throw const RecipeShoppingException('invalid_authority');
    }
    return value;
  }

  @override
  bool operator ==(Object other) =>
      other is RecipeShoppingAuthorityFacts &&
      kind == other.kind &&
      coreId == other.coreId &&
      homeId == other.homeId &&
      accountId == other.accountId &&
      sessionFamily == other.sessionFamily &&
      endpointBaseUrl == other.endpointBaseUrl &&
      identical(runtimeIdentity, other.runtimeIdentity) &&
      interactionEpoch == other.interactionEpoch;

  @override
  String toString() => 'RecipeShoppingAuthorityFacts(${kind.name})';

  @override
  int get hashCode => Object.hash(
    kind,
    coreId,
    homeId,
    accountId,
    sessionFamily,
    endpointBaseUrl,
    identityHashCode(runtimeIdentity),
    interactionEpoch,
  );
}

abstract interface class RecipeShoppingAuthoritySource {
  RecipeShoppingAuthorityFacts? read();
}

final class HomeRecipeShoppingAuthoritySource
    implements RecipeShoppingAuthoritySource {
  const HomeRecipeShoppingAuthoritySource(this.home);
  final HomeSessionController home;

  @override
  RecipeShoppingAuthorityFacts? read() {
    if (!home.interaction.active || home.busy || home.failure != null) {
      return null;
    }
    if (home.source == HomeSource.directLocal) {
      return RecipeShoppingAuthorityFacts.deviceLocal(
        runtimeIdentity: home.runtimeIdentity,
        interactionEpoch: home.interaction.epoch,
      );
    }
    if (home.source != HomeSource.verifiedCore) return null;
    final account = home.account;
    final session = account.session;
    final context = session?.context;
    if (session == null ||
        context == null ||
        account.working ||
        account.hasPendingContext ||
        session.authMutationPending ||
        session.user.mustChangePassword) {
      return null;
    }
    return RecipeShoppingAuthorityFacts.core(
      coreId: context.coreId,
      homeId: context.homeId,
      accountId: session.user.id,
      sessionFamily: account.generation,
      endpointBaseUrl: session.endpoint.baseUrl,
      runtimeIdentity: home.runtimeIdentity,
      interactionEpoch: home.interaction.epoch,
    );
  }
}

final class RecipeShoppingAuthorityLease {
  const RecipeShoppingAuthorityLease._(this._facts);
  final RecipeShoppingAuthorityFacts _facts;

  static RecipeShoppingAuthorityLease? capture(
    RecipeShoppingAuthoritySource source,
  ) {
    final facts = source.read();
    return facts == null ? null : RecipeShoppingAuthorityLease._(facts);
  }

  bool isCurrent(RecipeShoppingAuthoritySource source) =>
      source.read() == _facts;

  @override
  String toString() =>
      'RecipeShoppingAuthorityLease(${_facts.kind.name == 'deviceLocal' ? 'deviceLocal' : 'core'})';
}

final class RecipeShoppingReceipt {
  const RecipeShoppingReceipt._(this.verifiedCount);
  final int verifiedCount;

  @override
  String toString() => 'RecipeShoppingReceipt(verified: $verifiedCount)';
}

final class RecipeShoppingHandoff {
  Future<RecipeShoppingReceipt> add({
    required RecipeShoppingDraft draft,
    required String locale,
    required TodayTodoList list,
    required TodayActions actions,
    required RecipeShoppingAuthorityLease authority,
    required RecipeShoppingAuthoritySource authoritySource,
    required bool Function() visible,
  }) async {
    if (!list.available ||
        !list.canAdd ||
        list.items.value == null ||
        list.items.issue != null) {
      throw const RecipeShoppingException('list_unavailable');
    }
    final summaries = draft.shoppingSummaries(locale);
    var completed = 0;
    for (final summary in summaries) {
      _check(authority, authoritySource, visible, completed);
      await actions.addTodoBound(
        list,
        summary,
        current: () => visible() && authority.isCurrent(authoritySource),
      );
      completed++;
      _check(authority, authoritySource, visible, completed);
    }
    return RecipeShoppingReceipt._(completed);
  }

  void _check(
    RecipeShoppingAuthorityLease authority,
    RecipeShoppingAuthoritySource source,
    bool Function() visible,
    int completed,
  ) {
    if (!visible() || !authority.isCurrent(source)) {
      throw RecipeShoppingException(
        'stale_authority',
        completedCount: completed,
      );
    }
  }
}
