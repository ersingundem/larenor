import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/service_root_scaffold.dart';
import '../../../../shared/widgets/settings_action_tile.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../../hub/presentation/media_session_state.dart';
import '../providers/jellyseerr_providers.dart';
import 'jellyseerr_status_label.dart';

class JellyseerrRequestsScreen extends ConsumerStatefulWidget {
  const JellyseerrRequestsScreen({super.key});

  @override
  ConsumerState<JellyseerrRequestsScreen> createState() =>
      _JellyseerrRequestsScreenState();
}

class _JellyseerrRequestsScreenState
    extends MediaSessionState<JellyseerrRequestsScreen> {
  bool _current(int generation, Object reading) =>
      sessionCurrent(generation) &&
      TickerMode.valuesOf(context).enabled &&
      ModalRoute.of(context)?.isCurrent == true &&
      identical(ref.read(jellyseerrMyRequestsProvider), reading);

  @override
  Widget build(BuildContext context) {
    final requestsAsync = ref.watch(jellyseerrMyRequestsProvider);
    final l10n = AppLocalizations.of(context);
    final generation = sessionGeneration;
    final active = _current(generation, requestsAsync);

    return ServiceRootScaffold(
      title: l10n.jellyseerrMyRequestsTitle,
      slivers: [
        SliverToBoxAdapter(
          child: SettingsSection(
            header: Semantics(
              key: const ValueKey('jellyseerr-requests-section-title'),
              container: true,
              header: true,
              child: Text(l10n.jellyseerrMyRequestsTitle),
            ),
            children: [
              SettingsActionTile(
                buttonKey: const ValueKey('jellyseerr-requests-refresh'),
                leading: const Icon(CupertinoIcons.refresh),
                title: Text(l10n.commonRefresh),
                onTap: active
                    ? () {
                        if (_current(generation, requestsAsync)) {
                          ref.invalidate(jellyseerrMyRequestsProvider);
                        }
                      }
                    : null,
              ),
            ],
          ),
        ),
        ...requestsAsync.when(
          loading: () => [
            SliverFilledMessage(
              child: _RequestsStatus(label: l10n.commonLoading, loading: true),
            ),
          ],
          error: (_, _) => [
            SliverFilledMessage(
              child: _RequestsStatus(label: l10n.mediaErrorUnreachable),
            ),
          ],
          data: (requests) {
            if (requests.isEmpty) {
              return [
                SliverFilledMessage(
                  child: _RequestsStatus(label: l10n.jellyseerrNoRequestsYet),
                ),
              ];
            }
            return [
              SliverToBoxAdapter(
                child: SettingsSection(
                  children: [
                    for (final request in requests)
                      CupertinoListTile(
                        leading: Icon(
                          request.mediaType == 'tv'
                              ? CupertinoIcons.tv
                              : CupertinoIcons.film,
                        ),
                        title: Text(request.displayTitle),
                        additionalInfo: Text(
                          jellyseerrRequestStatusLabel(context, request.status),
                        ),
                      ),
                  ],
                ),
              ),
            ];
          },
        ),
      ],
    );
  }
}

class _RequestsStatus extends StatelessWidget {
  const _RequestsStatus({required this.label, this.loading = false});

  final String label;
  final bool loading;

  @override
  Widget build(BuildContext context) => Center(
    child: Semantics(
      key: const ValueKey('jellyseerr-requests-status'),
      label: label,
      liveRegion: true,
      excludeSemantics: true,
      child: loading
          ? const CupertinoActivityIndicator()
          : Padding(
              padding: const EdgeInsets.all(24),
              child: Text(label, textAlign: TextAlign.center),
            ),
    ),
  );
}
