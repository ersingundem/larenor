import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../data/server_account_controller.dart';
import '../../providers/server_providers.dart';
import '../data/server_family_memories_controller.dart';
import 'server_family_memories_screen.dart';

class ServerFamilyMemoriesRoute extends ConsumerStatefulWidget {
  const ServerFamilyMemoriesRoute({super.key, required this.gateCurrent});

  final bool Function() gateCurrent;

  @override
  ConsumerState<ServerFamilyMemoriesRoute> createState() =>
      _ServerFamilyMemoriesRouteState();
}

class _ServerFamilyMemoriesRouteState
    extends ConsumerState<ServerFamilyMemoriesRoute> {
  late final ServerAccountController _account;
  late final ServerFamilyMemoriesController _controller;
  late final int _accountGeneration;

  bool _current() =>
      mounted &&
      widget.gateCurrent() &&
      ModalRoute.of(context)?.isCurrent == true &&
      _account.isCurrent(_accountGeneration) &&
      _account.initialized &&
      !_account.working &&
      _account.session != null;

  @override
  void initState() {
    super.initState();
    _account = ref.read(serverAccountControllerProvider);
    _accountGeneration = _account.generation;
    _controller = ServerFamilyMemoriesController(_account);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ServerFamilyMemoriesScreen(
      controller: _controller,
      current: _current,
      labels: FamilyMemoriesLabels(
        title: l10n.serverFamilyMemoriesTitle,
        searchHint: l10n.serverFamilyMemoriesSearchHint,
        search: l10n.serverFamilyMemoriesSearch,
        albums: l10n.serverFamilyMemoriesAlbums,
        results: l10n.serverFamilyMemoriesResults,
        empty: l10n.serverFamilyMemoriesEmpty,
        createAlbum: l10n.serverFamilyMemoriesCreateAlbum,
        albumNameHint: l10n.serverFamilyMemoriesAlbumNameHint,
        personal: l10n.serverFamilyMemoriesPersonal,
        shared: l10n.serverFamilyMemoriesShared,
        cancel: l10n.serverFamilyMemoriesCancel,
        save: l10n.serverFamilyMemoriesSave,
        retry: l10n.serverFamilyMemoriesRetry,
        editAlbum: l10n.serverFamilyMemoriesEditAlbum,
        reconcile: l10n.serverFamilyMemoriesReconcile,
        delete: l10n.serverFamilyMemoriesDelete,
        deleteConfirm: l10n.serverFamilyMemoriesDeleteConfirm,
        items: l10n.serverFamilyMemoriesItems,
      ),
    );
  }
}
