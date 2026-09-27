import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../music_manager/domain/server_music_manager_models.dart';
import '../data/server_party_dj_controller.dart';
import '../domain/server_party_dj_models.dart';

final class ServerPartyDjScreen extends StatefulWidget {
  const ServerPartyDjScreen({
    required this.controller,
    required this.current,
    required this.turkish,
    super.key,
  });

  final ServerPartyDjController controller;
  final bool Function() current;
  final bool turkish;

  @override
  State<ServerPartyDjScreen> createState() => _ServerPartyDjScreenState();
}

final class _ServerPartyDjScreenState extends State<ServerPartyDjScreen> {
  final _invite = TextEditingController();
  final _query = TextEditingController();

  String _t(String en, String tr) => widget.turkish ? tr : en;

  @override
  void dispose() {
    _invite.dispose();
    _query.dispose();
    super.dispose();
  }

  String _error(String code) => switch (code) {
    'party_dj_room_changed' ||
    'party_dj_participant_changed' ||
    'party_dj_proposal_changed' ||
    'party_dj_authority_changed' ||
    'party_dj_target_changed' ||
    'party_dj_session_changed' => _t(
      'The room changed. Refresh and try again.',
      'Oda değişti. Yenileyip yeniden deneyin.',
    ),
    'party_dj_proposal_limit_reached' ||
    'party_dj_room_proposal_limit_reached' => _t(
      'You reached your song proposal limit.',
      'Şarkı önerisi sınırınıza ulaştınız.',
    ),
    'party_dj_proposal_conflict' => _t(
      'You already suggested this song.',
      'Bu şarkıyı zaten önerdiniz.',
    ),
    'party_dj_participant_limit_reached' || 'party_dj_room_limit_reached' => _t(
      'The Party DJ capacity is full.',
      'Parti DJ kapasitesi dolu.',
    ),
    'party_dj_skip_needs_attention' => _t(
      'Refresh before another skip vote.',
      'Başka bir geçme oyundan önce yenileyin.',
    ),
    'party_dj_host_required' => _t(
      'Only the host can do that.',
      'Bu işlemi yalnız sunucu yapabilir.',
    ),
    'party_dj_room_closed' ||
    'party_dj_room_expired' => _t('This room is closed.', 'Bu oda kapandı.'),
    'party_dj_target_unavailable' ||
    'party_dj_target_capability_unavailable' ||
    'music_manager_unavailable' ||
    'music_provider_unavailable' => _t(
      'Music Assistant is not ready for this room.',
      'Music Assistant bu oda için hazır değil.',
    ),
    'invalid_request' => _t(
      'Check the invitation or song details.',
      'Davet veya şarkı bilgilerini kontrol edin.',
    ),
    'connection_failed' => _t(
      'Could not reach Core.',
      'Core bağlantısı kurulamadı.',
    ),
    _ => _t('The operation could not be completed.', 'İşlem tamamlanamadı.'),
  };

  Future<bool> _confirm(String title, String detail) async =>
      await showCupertinoDialog<bool>(
        context: context,
        builder: (dialog) => CupertinoAlertDialog(
          title: Text(title),
          content: Text(detail),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(_t('Cancel', 'Vazgeç')),
            ),
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(_t('Confirm', 'Onayla')),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _chooseProvider() async {
    final manager = widget.controller.manager;
    if (manager == null || manager.providers.isEmpty) return;
    final selected = await showCupertinoModalPopup<ServerMusicProviderBinding>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
        title: Text(_t('Music provider', 'Müzik sağlayıcısı')),
        actions: [
          for (final provider in manager.providers)
            CupertinoActionSheetAction(
              isDefaultAction:
                  provider.setupId ==
                  widget.controller.selectedProvider?.setupId,
              onPressed: () => Navigator.pop(sheet, provider),
              child: Text(provider.domain),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(sheet),
          child: Text(_t('Cancel', 'Vazgeç')),
        ),
      ),
    );
    if (selected != null && widget.current()) {
      widget.controller.selectProvider(selected);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final room = widget.controller.room;
      return CupertinoPageScaffold(
        navigationBar: CupertinoNavigationBar(
          middle: Text(_t('Party DJ', 'Parti DJ')),
          trailing: room == null
              ? null
              : CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: widget.controller.busy || !widget.current()
                      ? null
                      : () =>
                            widget.controller.refresh(current: widget.current),
                  child: const Icon(CupertinoIcons.refresh),
                ),
        ),
        child: SafeArea(child: room == null ? _lobby() : _room(room)),
      );
    },
  );

  Widget _lobby() {
    final controller = widget.controller;
    final manager = controller.manager;
    final targets = manager?.receivers
        .where(
          (item) =>
              item.available &&
              item.enabled &&
              item.supports(ServerMusicOperation.queueAdd) &&
              item.capabilities.contains('next_previous'),
        )
        .toList(growable: false);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
      children: [
        _HeroCard(
          icon: CupertinoIcons.music_mic,
          title: _t('Shared music queue', 'Ortak müzik kuyruğu'),
          detail: _t(
            'Guests suggest and vote. The host keeps the final say, while skip votes follow the room quorum.',
            'Misafirler önerir ve oylar. Son karar sunucuda kalır; geçme oyları oda çoğunluğuna göre uygulanır.',
          ),
        ),
        if (controller.hasPendingEffect) ...[
          const SizedBox(height: 14),
          _StatusBanner(
            message: _t(
              'Room setup has an unknown result. Resume the protected request before starting or joining another room.',
              'Oda kurulumunun sonucu belirsiz. Başka bir oda başlatmadan veya odaya katılmadan önce korumalı isteği sürdürün.',
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: CupertinoButton(
              onPressed: controller.busy || !widget.current()
                  ? null
                  : () => controller.retryPending(current: widget.current),
              child: Text(_t('Resume room setup', 'Oda kurulumunu sürdür')),
            ),
          ),
        ],
        if (controller.failure != null) ...[
          const SizedBox(height: 14),
          _FailureBanner(message: _error(controller.failure!)),
        ],
        if (controller.canHostLaunch) ...[
          const SizedBox(height: 24),
          Text(
            _t('Create a room', 'Oda oluştur'),
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          if (manager == null)
            CupertinoButton.filled(
              onPressed:
                  controller.busy ||
                      controller.hasPendingEffect ||
                      !widget.current()
                  ? null
                  : () => controller.loadSetup(current: widget.current),
              child: controller.busy
                  ? const CupertinoActivityIndicator()
                  : Text(_t('Load Music Assistant', 'Music Assistant’ı yükle')),
            )
          else if (targets!.isEmpty)
            Text(
              _t(
                'No available player with queue support was found.',
                'Kuyruk desteği olan kullanılabilir oynatıcı bulunamadı.',
              ),
            )
          else
            for (final target in targets)
              _TargetCard(
                target: target,
                busy: controller.busy || controller.hasPendingEffect,
                createLabel: _t('Start room', 'Odayı başlat'),
                onCreate: () async {
                  if (await _confirm(
                        _t('Start Party DJ?', 'Parti DJ başlatılsın mı?'),
                        _t(
                          '${target.name} will become the shared queue target.',
                          '${target.name} ortak kuyruk hedefi olacak.',
                        ),
                      ) &&
                      widget.current()) {
                    await controller.create(target, current: widget.current);
                  }
                },
              ),
          const SizedBox(height: 28),
        ] else
          const SizedBox(height: 24),
        Text(
          _t('Join with invitation', 'Davetle katıl'),
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        CupertinoTextField(
          controller: _invite,
          enabled: !controller.busy && !controller.hasPendingEffect,
          autocorrect: false,
          textCapitalization: TextCapitalization.none,
          placeholder: _t('Paste room invitation', 'Oda davetini yapıştırın'),
          clearButtonMode: OverlayVisibilityMode.editing,
        ),
        const SizedBox(height: 10),
        CupertinoButton.filled(
          onPressed:
              controller.busy ||
                  controller.hasPendingEffect ||
                  !widget.current()
              ? null
              : () => controller.join(_invite.text, current: widget.current),
          child: Text(_t('Join room', 'Odaya katıl')),
        ),
      ],
    );
  }

  Widget _room(ServerPartyDjRoom room) {
    final controller = widget.controller;
    final connected = room.participants.where((item) => item.connected).length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 42),
      children: [
        _HeroCard(
          icon: CupertinoIcons.person_3_fill,
          title: _t('Party room', 'Parti odası'),
          detail: _t(
            '$connected of ${room.participants.length} participants connected · Skip ${room.skipVotes}/${room.skipVotesRequired}',
            '${room.participants.length} katılımcının $connected tanesi bağlı · Geçme ${room.skipVotes}/${room.skipVotesRequired}',
          ),
        ),
        if (controller.invitation != null) ...[
          const SizedBox(height: 12),
          _InvitationCard(
            label: _t('Share invitation', 'Daveti paylaş'),
            value: controller.invitation!.value,
          ),
        ],
        if (controller.failure != null) ...[
          const SizedBox(height: 12),
          _FailureBanner(message: _error(controller.failure!)),
        ],
        if (controller.hasPendingEffect) ...[
          const SizedBox(height: 12),
          _StatusBanner(
            message: _t(
              'A Party DJ operation has an unknown result. Resume it with the same protected request before continuing.',
              'Bir Parti DJ işleminin sonucu belirsiz. Devam etmeden önce aynı korumalı istekle işlemi sürdürün.',
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: CupertinoButton(
              onPressed: controller.busy || !widget.current()
                  ? null
                  : () => controller.retryPending(current: widget.current),
              child: Text(_t('Resume operation', 'İşlemi sürdür')),
            ),
          ),
        ],
        if (room.skipNeedsAttention) ...[
          const SizedBox(height: 12),
          _FailureBanner(
            message: _t(
              'The last skip reached quorum but its playback result is uncertain. Refresh before voting again.',
              'Son geçme oyu çoğunluğa ulaştı ancak oynatma sonucu belirsiz. Yeniden oylamadan önce yenileyin.',
            ),
          ),
          if (room.isHost)
            Align(
              alignment: Alignment.centerRight,
              child: CupertinoButton(
                onPressed: controller.busy || !widget.current()
                    ? null
                    : () => controller.dismissSkip(current: widget.current),
                child: Text(
                  _t('Dismiss unresolved skip', 'Belirsiz geçişi kapat'),
                ),
              ),
            ),
        ] else if (room.skipQuorumReached) ...[
          const SizedBox(height: 12),
          _StatusBanner(
            message: _t(
              'Skip quorum reached. Playback is reconciling; refresh for the final result.',
              'Geçme çoğunluğuna ulaşıldı. Oynatma uzlaştırılıyor; kesin sonuç için yenileyin.',
            ),
          ),
        ],
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: CupertinoButton.filled(
                onPressed:
                    controller.busy ||
                        room.skipNeedsAttention ||
                        room.skipQuorumReached ||
                        !widget.current()
                    ? null
                    : () => controller.voteToSkip(current: widget.current),
                child: Text(
                  room.skipQuorumReached
                      ? _t('Reconciling skip', 'Geçiş uzlaştırılıyor')
                      : _t(
                          'Vote to skip (${room.skipVotes}/${room.skipVotesRequired})',
                          'Geçmek için oyla (${room.skipVotes}/${room.skipVotesRequired})',
                        ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            CupertinoButton(
              color: CupertinoColors.systemRed,
              onPressed: controller.busy || !widget.current()
                  ? null
                  : () async {
                      if (await _confirm(
                            _t('Leave room?', 'Odadan ayrıl?'),
                            room.isHost
                                ? _t(
                                    'Hosting passes safely when another participant remains.',
                                    'Başka katılımcı varsa sunuculuk güvenle devredilir.',
                                  )
                                : _t(
                                    'You can rejoin later with a current invitation.',
                                    'Güncel bir davetle daha sonra tekrar katılabilirsiniz.',
                                  ),
                          ) &&
                          widget.current()) {
                        await controller.leave(current: widget.current);
                      }
                    },
              child: Text(_t('Leave', 'Ayrıl')),
            ),
          ],
        ),
        const SizedBox(height: 26),
        _SectionTitle(
          title: _t('Participants', 'Katılımcılar'),
          detail: _t(
            'Disconnected members remain visible until the room reconciles.',
            'Bağlantısı kesilen üyeler oda uzlaşana kadar görünür kalır.',
          ),
        ),
        for (final participant in room.participants)
          _ParticipantRow(
            participant: participant,
            hostLabel: _t('Host', 'Sunucu'),
            onlineLabel: _t('Connected', 'Bağlı'),
            offlineLabel: _t('Disconnected', 'Bağlantı kesildi'),
            youLabel: _t('You', 'Siz'),
          ),
        const SizedBox(height: 26),
        _SectionTitle(
          title: _t('Suggest a song', 'Şarkı öner'),
          detail: _t(
            '${room.currentUserProposalCount}/${room.proposalLimitPerUser} active proposals',
            '${room.currentUserProposalCount}/${room.proposalLimitPerUser} etkin öneri',
          ),
        ),
        if (!room.canPropose)
          Text(
            _t(
              'Your proposal slots are full. Wait for a host decision.',
              'Öneri alanlarınız dolu. Sunucu kararını bekleyin.',
            ),
          )
        else ...[
          Row(
            children: [
              Expanded(
                child: CupertinoTextField(
                  controller: _query,
                  enabled: !controller.busy,
                  placeholder: _t('Search tracks', 'Şarkı ara'),
                  clearButtonMode: OverlayVisibilityMode.editing,
                  onSubmitted: (_) =>
                      controller.search(_query.text, current: widget.current),
                ),
              ),
              const SizedBox(width: 8),
              CupertinoButton(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                onPressed: controller.busy || !widget.current()
                    ? null
                    : _chooseProvider,
                child: Text(
                  controller.selectedProvider?.domain ??
                      _t('Provider', 'Sağlayıcı'),
                ),
              ),
              CupertinoButton(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                onPressed: controller.busy || !widget.current()
                    ? null
                    : () => controller.search(
                        _query.text,
                        current: widget.current,
                      ),
                child: const Icon(CupertinoIcons.search),
              ),
            ],
          ),
          for (final item in controller.searchResults)
            _SearchResult(
              item: item,
              proposeLabel: _t('Suggest', 'Öner'),
              busy: controller.busy,
              onPropose: () =>
                  controller.propose(item, current: widget.current),
            ),
        ],
        const SizedBox(height: 26),
        _SectionTitle(
          title: _t('Song proposals', 'Şarkı önerileri'),
          detail: _t(
            'One vote per person. The host approves the final queue change.',
            'Kişi başına tek oy. Son kuyruk değişimini sunucu onaylar.',
          ),
        ),
        if (room.proposals.isEmpty)
          Text(_t('No proposals yet.', 'Henüz öneri yok.')),
        for (final proposal in room.proposals)
          _ProposalCard(
            proposal: proposal,
            isHost: room.isHost,
            busy: controller.busy,
            voteLabel: proposal.votedByCurrentUser
                ? _t('Remove vote', 'Oyu kaldır')
                : _t('Vote', 'Oyla'),
            approveLabel: _t('Approve', 'Onayla'),
            rejectLabel: _t('Reject', 'Reddet'),
            dismissLabel: _t('Dismiss', 'Kapat'),
            statusLabel: _proposalStatus(proposal.status),
            onVote: () => controller.vote(proposal, current: widget.current),
            onApprove: () => controller.decide(
              proposal,
              approve: true,
              current: widget.current,
            ),
            onReject: () => controller.decide(
              proposal,
              approve: false,
              current: widget.current,
            ),
            onDismiss: () =>
                controller.dismissProposal(proposal, current: widget.current),
          ),
      ],
    );
  }

  String _proposalStatus(ServerPartyDjProposalStatus value) => switch (value) {
    ServerPartyDjProposalStatus.pending => _t('Pending', 'Bekliyor'),
    ServerPartyDjProposalStatus.approving => _t('Approving', 'Onaylanıyor'),
    ServerPartyDjProposalStatus.approved => _t('Queued', 'Kuyruğa eklendi'),
    ServerPartyDjProposalStatus.rejected => _t('Rejected', 'Reddedildi'),
    ServerPartyDjProposalStatus.needsAttention => _t(
      'Needs attention',
      'İlgi gerekiyor',
    ),
  };
}

final class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.icon,
    required this.title,
    required this.detail,
  });
  final IconData icon;
  final String title, detail;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: CupertinoColors.systemIndigo.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(18),
    ),
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 34, color: CupertinoColors.systemIndigo),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                Text(detail),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

final class _FailureBanner extends StatelessWidget {
  const _FailureBanner({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: CupertinoColors.systemRed.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Text(
        message,
        style: const TextStyle(color: CupertinoColors.systemRed),
      ),
    ),
  );
}

final class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: CupertinoColors.systemIndigo.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Text(
        message,
        style: const TextStyle(color: CupertinoColors.systemIndigo),
      ),
    ),
  );
}

final class _TargetCard extends StatelessWidget {
  const _TargetCard({
    required this.target,
    required this.busy,
    required this.createLabel,
    required this.onCreate,
  });
  final ServerMusicReceiver target;
  final bool busy;
  final String createLabel;
  final VoidCallback onCreate;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: CupertinoDynamicColor.resolve(
          CupertinoColors.secondarySystemGroupedBackground,
          context,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            const Icon(CupertinoIcons.hifispeaker_fill),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    target.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text('${target.provider} · ${target.kind}'),
                ],
              ),
            ),
            CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              onPressed: busy ? null : onCreate,
              child: Text(createLabel),
            ),
          ],
        ),
      ),
    ),
  );
}

final class _InvitationCard extends StatelessWidget {
  const _InvitationCard({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: CupertinoColors.systemGrey6.resolveFrom(context),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 5),
          Row(
            children: [
              Expanded(
                child: Text(
                  value,
                  style: const TextStyle(fontSize: 12),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              CupertinoButton(
                padding: const EdgeInsets.all(6),
                onPressed: () => Clipboard.setData(ClipboardData(text: value)),
                child: const Icon(CupertinoIcons.doc_on_doc, size: 19),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

final class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.detail});
  final String title, detail;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 3),
        Text(detail, style: const TextStyle(fontSize: 13)),
      ],
    ),
  );
}

final class _ParticipantRow extends StatelessWidget {
  const _ParticipantRow({
    required this.participant,
    required this.hostLabel,
    required this.onlineLabel,
    required this.offlineLabel,
    required this.youLabel,
  });
  final ServerPartyDjParticipant participant;
  final String hostLabel, onlineLabel, offlineLabel, youLabel;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      children: [
        Icon(
          participant.connected
              ? CupertinoIcons.person_crop_circle_fill_badge_checkmark
              : CupertinoIcons.person_crop_circle_badge_xmark,
          color: participant.connected
              ? CupertinoColors.systemGreen
              : CupertinoColors.systemGrey,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            '${participant.accountId.substring(0, 8)}${participant.ownedByCurrentSession ? ' · $youLabel' : ''}',
          ),
        ),
        if (participant.isHost) ...[
          Text(hostLabel, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
        ],
        Text(
          participant.connected ? onlineLabel : offlineLabel,
          style: TextStyle(
            fontSize: 12,
            color: participant.connected
                ? CupertinoColors.systemGreen
                : CupertinoColors.systemGrey,
          ),
        ),
      ],
    ),
  );
}

final class _SearchResult extends StatelessWidget {
  const _SearchResult({
    required this.item,
    required this.proposeLabel,
    required this.busy,
    required this.onPropose,
  });
  final ServerMusicCatalogItem item;
  final String proposeLabel;
  final bool busy;
  final VoidCallback onPropose;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Row(
      children: [
        const Icon(CupertinoIcons.music_note_2),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis),
              if (item.artists.isNotEmpty)
                Text(
                  item.artists.join(', '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
            ],
          ),
        ),
        CupertinoButton(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          onPressed: busy ? null : onPropose,
          child: Text(proposeLabel),
        ),
      ],
    ),
  );
}

final class _ProposalCard extends StatelessWidget {
  const _ProposalCard({
    required this.proposal,
    required this.isHost,
    required this.busy,
    required this.voteLabel,
    required this.approveLabel,
    required this.rejectLabel,
    required this.dismissLabel,
    required this.statusLabel,
    required this.onVote,
    required this.onApprove,
    required this.onReject,
    required this.onDismiss,
  });
  final ServerPartyDjProposal proposal;
  final bool isHost, busy;
  final String voteLabel, approveLabel, rejectLabel, dismissLabel, statusLabel;
  final VoidCallback onVote, onApprove, onReject, onDismiss;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: CupertinoColors.systemGrey6.resolveFrom(context),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    proposal.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(statusLabel, style: const TextStyle(fontSize: 12)),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${proposal.upVotes} ♥ · ${proposal.accountId.substring(0, 8)}',
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  onPressed: busy || !proposal.pending ? null : onVote,
                  child: Text(voteLabel),
                ),
                if (isHost && proposal.pending) ...[
                  CupertinoButton(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    onPressed: busy ? null : onApprove,
                    child: Text(approveLabel),
                  ),
                  CupertinoButton(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    onPressed: busy ? null : onReject,
                    child: Text(
                      rejectLabel,
                      style: const TextStyle(color: CupertinoColors.systemRed),
                    ),
                  ),
                ] else if (isHost &&
                    proposal.status ==
                        ServerPartyDjProposalStatus.needsAttention) ...[
                  CupertinoButton(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    onPressed: busy ? null : onDismiss,
                    child: Text(dismissLabel),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
