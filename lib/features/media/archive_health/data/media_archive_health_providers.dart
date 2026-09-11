import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../server/domain/server_models.dart';
import '../../../server/providers/server_providers.dart';
import 'core_media_archive_api.dart';
import 'media_archive_health_controller.dart';

final mediaArchiveHealthControllerProvider =
    Provider.autoDispose<MediaArchiveHealthController>((ref) {
      final account = ref.read(serverAccountControllerProvider);
      bool authorized() =>
          account.initialized &&
          !account.working &&
          !account.hasPendingContext &&
          account.session?.user.canAdminister == true &&
          account.session?.authMutationPending == false &&
          account.session?.user.mustChangePassword == false;
      final controller = MediaArchiveHealthController(
        authority: account,
        authorityRevision: () => account.generation,
        authorized: authorized,
        read: () async {
          final generation = account.generation;
          return account.withSession((api, session) async {
            if (!account.isCurrent(generation) ||
                !authorized() ||
                !identical(account.session, session)) {
              throw const LarenorServerException('cancelled');
            }
            final value = await CoreMediaArchiveApi(
              api,
              session.accessToken,
            ).read();
            if (!account.isCurrent(generation) ||
                !authorized() ||
                !identical(account.session, session)) {
              throw const LarenorServerException('cancelled');
            }
            return value;
          });
        },
      );
      ref.onDispose(controller.dispose);
      return controller;
    });
