import 'package:flutter/cupertino.dart';

import '../data/server_media_archive_actions_controller.dart';
import '../domain/server_media_archive_action_models.dart';

final class ServerMediaArchiveActionsScreen extends StatelessWidget {
  const ServerMediaArchiveActionsScreen({
    required this.controller,
    required this.current,
    required this.turkish,
    super.key,
  });

  final ServerMediaArchiveActionsController controller;
  final bool Function() current;
  final bool turkish;

  String _t(String tr, String en) => turkish ? tr : en;

  String _bytes(int value) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var amount = value.toDouble();
    var index = 0;
    while (amount >= 1024 && index < units.length - 1) {
      amount /= 1024;
      index++;
    }
    final digits = amount >= 100 || index == 0 ? 0 : 1;
    return '${amount.toStringAsFixed(digits)} ${units[index]}';
  }

  String _words(String value) => value
      .split('_')
      .map(
        (word) => word.isEmpty
            ? word
            : '${word[0].toUpperCase()}${word.substring(1)}',
      )
      .join(' ');

  String _failure(String code) => switch (code) {
    'media_archive_action_quota_exceeded' => _t(
      'Ortak arşiv kotasında yeterli boşluk yok.',
      'The shared archive quota does not have enough space.',
    ),
    'media_archive_action_preview_expired' => _t(
      'Önizlemenin süresi doldu. Kanıtı yeniden hazırlayın.',
      'The preview expired. Prepare the evidence again.',
    ),
    'media_archive_action_authority_changed' ||
    'media_archive_action_evidence_changed' => _t(
      'Arşiv kanıtı değişti. Ekranı yenileyin.',
      'The archive evidence changed. Refresh this screen.',
    ),
    'media_archive_action_policy_changed' ||
    'media_archive_action_job_changed' => _t(
      'Arşiv işlem durumu değişti. Ekranı yenileyin.',
      'The archive action state changed. Refresh this screen.',
    ),
    'media_archive_action_request_conflict' => _t(
      'Bu istek daha önce farklı içerikle kaydedildi.',
      'This request was already stored with different content.',
    ),
    'media_archive_action_preview_limit' ||
    'media_archive_action_job_limit' => _t(
      'Arşiv işlem sınırına ulaşıldı. Eski işleri gözden geçirin.',
      'The archive action limit was reached. Review older jobs.',
    ),
    'media_archive_action_cleanup_already_confirmed' => _t(
      'Bu korunan orijinal için cleanup zaten onaylandı.',
      'Cleanup was already confirmed for this retained original.',
    ),
    'media_archive_action_unavailable' ||
    'media_archive_action_worker_unavailable' ||
    'media_archive_action_storage_unavailable' => _t(
      'Arşiv işlem hizmeti şu anda kullanılamıyor.',
      'The archive action service is currently unavailable.',
    ),
    'forbidden' || 'unauthorized' => _t(
      'Bu işlem için yönetici yetkisi gerekli.',
      'Administrator access is required.',
    ),
    'connection_failed' || 'timeout' || 'server_error' => _t(
      'Core bağlantısı kurulamadı.',
      'Could not reach Core.',
    ),
    _ => _t('İşlem tamamlanamadı.', 'The operation could not be completed.'),
  };

  Future<void> _editQuota(
    BuildContext context,
    ServerMediaArchivePolicy policy,
  ) async {
    final input = TextEditingController(
      text: '${policy.sharedQuotaBytes ~/ (1024 * 1024 * 1024)}',
    );
    final value = await showCupertinoDialog<int>(
      context: context,
      builder: (dialog) => CupertinoAlertDialog(
        title: Text(_t('Ortak arşiv kotası', 'Shared archive quota')),
        content: Column(
          children: [
            const SizedBox(height: 8),
            Text(
              _t(
                'GB cinsinden 1–10240 arası bir değer girin. Ayrılmış alanın altına inemez.',
                'Enter 1–10240 GB. It cannot be smaller than reserved space.',
              ),
            ),
            const SizedBox(height: 12),
            CupertinoTextField(
              controller: input,
              keyboardType: TextInputType.number,
              placeholder: _t('GB', 'GB'),
              clearButtonMode: OverlayVisibilityMode.editing,
            ),
          ],
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialog),
            child: Text(_t('Vazgeç', 'Cancel')),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () {
              final gib = int.tryParse(input.text.trim());
              final bytes = gib == null ? null : gib * 1024 * 1024 * 1024;
              if (gib == null ||
                  gib < 1 ||
                  gib > 10240 ||
                  bytes! < policy.reservedBytes) {
                return;
              }
              Navigator.pop(dialog, bytes);
            },
            child: Text(_t('Kaydet', 'Save')),
          ),
        ],
      ),
    );
    input.dispose();
    if (value != null && current()) {
      await controller.updateQuota(sharedQuotaBytes: value, current: current);
    }
  }

  Future<bool> _confirm(
    BuildContext context, {
    required String title,
    required String message,
    required bool destructive,
  }) async =>
      await showCupertinoDialog<bool>(
        context: context,
        builder: (dialog) => CupertinoAlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(_t('Vazgeç', 'Cancel')),
            ),
            CupertinoDialogAction(
              isDefaultAction: !destructive,
              isDestructiveAction: destructive,
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(_t('Onayla', 'Confirm')),
            ),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final snapshot = controller.snapshot;
      return CupertinoPageScaffold(
        navigationBar: CupertinoNavigationBar(
          middle: Text(_t('Arşiv işlemleri', 'Archive actions')),
          trailing: CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: controller.busy || !current()
                ? null
                : () => controller.load(current: current),
            child: const Icon(CupertinoIcons.refresh),
          ),
        ),
        child: SafeArea(
          child: snapshot == null
              ? _ArchiveEmptyState(
                  busy: controller.busy,
                  message: controller.failure == null
                      ? _t(
                          'Kanıt bağlı arşiv işlemleri yükleniyor…',
                          'Loading evidence-bound archive actions…',
                        )
                      : _failure(controller.failure!),
                  retryLabel: _t('Yeniden dene', 'Retry'),
                  onRetry: () => controller.load(current: current),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 40),
                  children: [
                    _PolicyCard(
                      policy: snapshot.policy,
                      bytes: _bytes,
                      turkish: turkish,
                      busy: controller.busy,
                      onEdit: () => _editQuota(context, snapshot.policy),
                    ),
                    if (controller.requiresRefresh) ...[
                      const SizedBox(height: 12),
                      _NoticeCard(
                        icon: CupertinoIcons.arrow_clockwise_circle,
                        message: _t(
                          'Son yazmanın sonucu kesin değil. Yeni işlem başlatmadan önce ekranı yenileyin.',
                          'The last write is uncertain. Refresh before starting another action.',
                        ),
                        actionLabel: _t('Yenile', 'Refresh'),
                        onAction: controller.busy
                            ? null
                            : () => controller.load(current: current),
                      ),
                    ],
                    if (controller.failure != null) ...[
                      const SizedBox(height: 12),
                      _NoticeCard(
                        icon: CupertinoIcons.exclamationmark_triangle,
                        message: _failure(controller.failure!),
                      ),
                    ],
                    if (controller.preview != null) ...[
                      const SizedBox(height: 20),
                      _PreviewCard(
                        preview: controller.preview!,
                        bytes: _bytes,
                        turkish: turkish,
                        busy: controller.busy,
                        onDismiss: controller.dismissPreview,
                        onConfirm: () async {
                          final preview = controller.preview;
                          if (preview == null) return;
                          final cleanup =
                              preview.operation !=
                              ServerMediaArchivePreviewOperation.stageTranscode;
                          final accepted = await _confirm(
                            context,
                            title: cleanup
                                ? _t('Temizliği onayla', 'Confirm cleanup')
                                : _t('Dönüşümü başlat', 'Start optimization'),
                            message: cleanup
                                ? _t(
                                    'Bu ayrı cleanup işi seçilen korunan veriyi kaldırır. Otomatik silme kapalı kalır.',
                                    'This separate cleanup job removes the selected retained data. Automatic cleanup stays disabled.',
                                  )
                                : _t(
                                    'Dönüşüm staging alanında çalışır ve orijinal dosyayı korur.',
                                    'Optimization runs in staging and retains the original file.',
                                  ),
                            destructive: cleanup,
                          );
                          if (accepted && current()) {
                            await controller.confirmPreview(current: current);
                          }
                        },
                      ),
                    ],
                    const SizedBox(height: 24),
                    _SectionTitle(
                      title: _t(
                        'Kanıtlı adaylar',
                        'Evidence-backed candidates',
                      ),
                      detail: _t(
                        '${snapshot.candidates.length} aday · otomatik silme kapalı',
                        '${snapshot.candidates.length} candidates · automatic cleanup off',
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (snapshot.candidates.isEmpty)
                      _NoticeCard(
                        icon: CupertinoIcons.check_mark_circled,
                        message: _t(
                          'Bu sağlık görüntüsünde işlem adayı yok.',
                          'This health snapshot has no action candidate.',
                        ),
                      ),
                    for (final candidate in snapshot.candidates) ...[
                      _CandidateCard(
                        candidate: candidate,
                        bytes: _bytes,
                        words: _words,
                        turkish: turkish,
                        busy: controller.busy || controller.requiresRefresh,
                        onPreview: () => controller.previewCandidate(
                          candidate,
                          current: current,
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    const SizedBox(height: 14),
                    _SectionTitle(
                      title: _t('Dayanıklı işler', 'Durable jobs'),
                      detail: _t(
                        '${snapshot.jobs.length} kayıt',
                        '${snapshot.jobs.length} records',
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (snapshot.jobs.isEmpty)
                      _NoticeCard(
                        icon: CupertinoIcons.tray,
                        message: _t(
                          'Henüz arşiv işi başlatılmadı.',
                          'No archive job has been started.',
                        ),
                      ),
                    for (final job in snapshot.jobs) ...[
                      _JobCard(
                        job: job,
                        bytes: _bytes,
                        words: _words,
                        turkish: turkish,
                        busy: controller.busy || controller.requiresRefresh,
                        onRefresh: () =>
                            controller.refreshJob(job, current: current),
                        onCancel: job.canCancel
                            ? () async {
                                final accepted = await _confirm(
                                  context,
                                  title: _t('İşi iptal et', 'Cancel job'),
                                  message: _t(
                                    'İptal isteği durable işe yazılır. Etki belirsizse iş uzlaştırma bekler.',
                                    'The cancellation is recorded durably. An uncertain effect waits for reconciliation.',
                                  ),
                                  destructive: true,
                                );
                                if (accepted && current()) {
                                  await controller.cancelJob(
                                    job,
                                    current: current,
                                  );
                                }
                              }
                            : null,
                        onReconcile: job.canReconcile
                            ? () =>
                                  controller.reconcileJob(job, current: current)
                            : null,
                        onCleanup: job.cleanupAvailable
                            ? () => controller.previewCleanupJob(
                                job,
                                current: current,
                              )
                            : null,
                      ),
                      const SizedBox(height: 10),
                    ],
                  ],
                ),
        ),
      );
    },
  );
}

final class _ArchiveEmptyState extends StatelessWidget {
  const _ArchiveEmptyState({
    required this.busy,
    required this.message,
    required this.retryLabel,
    required this.onRetry,
  });
  final bool busy;
  final String message, retryLabel;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy) const CupertinoActivityIndicator(),
          if (busy) const SizedBox(height: 14),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          CupertinoButton(
            onPressed: busy ? null : onRetry,
            child: Text(retryLabel),
          ),
        ],
      ),
    ),
  );
}

final class _PolicyCard extends StatelessWidget {
  const _PolicyCard({
    required this.policy,
    required this.bytes,
    required this.turkish,
    required this.busy,
    required this.onEdit,
  });
  final ServerMediaArchivePolicy policy;
  final String Function(int) bytes;
  final bool turkish, busy;
  final VoidCallback onEdit;
  String _t(String tr, String en) => turkish ? tr : en;
  @override
  Widget build(BuildContext context) => _Card(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(CupertinoIcons.archivebox, size: 28),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _t('Ortak staging kotası', 'Shared staging quota'),
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              onPressed: busy ? null : onEdit,
              child: Text(_t('Düzenle', 'Edit')),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _KeyValue(
          label: _t('Toplam', 'Total'),
          value: bytes(policy.sharedQuotaBytes),
        ),
        _KeyValue(
          label: _t('Ayrılmış', 'Reserved'),
          value: bytes(policy.reservedBytes),
        ),
        _KeyValue(
          label: _t('Kullanılabilir', 'Available'),
          value: bytes(policy.availableBytes),
        ),
        const SizedBox(height: 8),
        Text(
          _t(
            'Otomatik cleanup kapalıdır. Her silme ayrı önizleme ve onay ister.',
            'Automatic cleanup is off. Every deletion requires a separate preview and confirmation.',
          ),
          style: const TextStyle(color: CupertinoColors.secondaryLabel),
        ),
      ],
    ),
  );
}

final class _CandidateCard extends StatelessWidget {
  const _CandidateCard({
    required this.candidate,
    required this.bytes,
    required this.words,
    required this.turkish,
    required this.busy,
    required this.onPreview,
  });
  final ServerMediaArchiveCandidate candidate;
  final String Function(int) bytes;
  final String Function(String) words;
  final bool turkish, busy;
  final VoidCallback onPreview;
  String _t(String tr, String en) => turkish ? tr : en;
  @override
  Widget build(BuildContext context) => _Card(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              candidate.actionType == ServerMediaArchiveActionType.optimize
                  ? CupertinoIcons.wand_stars
                  : CupertinoIcons.delete,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    candidate.title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${words(candidate.kind.name)} · ${bytes(candidate.potentialBytes)}',
                    style: const TextStyle(
                      color: CupertinoColors.secondaryLabel,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          _t('Kanıt', 'Evidence'),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 5),
        for (final evidence in candidate.evidence)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(CupertinoIcons.check_mark_circled_solid, size: 17),
                const SizedBox(width: 7),
                Expanded(child: Text(words(evidence))),
              ],
            ),
          ),
        const SizedBox(height: 8),
        _KeyValue(
          label: _t('Gözlenen', 'Observed'),
          value: bytes(candidate.comparison.observedBytes),
        ),
        _KeyValue(
          label: _t('Korunacak', 'Retained'),
          value: bytes(candidate.comparison.estimatedRetainedBytes),
        ),
        const SizedBox(height: 10),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: CupertinoButton.filled(
            onPressed: busy ? null : onPreview,
            child: Text(
              candidate.actionType == ServerMediaArchiveActionType.optimize
                  ? _t('Dönüşümü önizle', 'Preview optimization')
                  : _t('Cleanup önizle', 'Preview cleanup'),
            ),
          ),
        ),
      ],
    ),
  );
}

final class _PreviewCard extends StatelessWidget {
  const _PreviewCard({
    required this.preview,
    required this.bytes,
    required this.turkish,
    required this.busy,
    required this.onDismiss,
    required this.onConfirm,
  });
  final ServerMediaArchivePreview preview;
  final String Function(int) bytes;
  final bool turkish, busy;
  final VoidCallback onDismiss, onConfirm;
  String _t(String tr, String en) => turkish ? tr : en;
  @override
  Widget build(BuildContext context) {
    final optimize =
        preview.operation == ServerMediaArchivePreviewOperation.stageTranscode;
    return _Card(
      accent: optimize
          ? CupertinoColors.systemBlue
          : CupertinoColors.systemOrange,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            optimize
                ? _t('Dönüşüm önizlemesi', 'Optimization preview')
                : _t('Cleanup önizlemesi', 'Cleanup preview'),
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            optimize
                ? _t(
                    'Orijinal dosya korunur. Staging rezervi: ${bytes(preview.reservedBytes)}.',
                    'The original is retained. Staging reservation: ${bytes(preview.reservedBytes)}.',
                  )
                : _t(
                    'Bu ayrı işlem korunan veriyi kaldırır. Geri alma otomatik değildir.',
                    'This separate action removes retained data. Recovery is not automatic.',
                  ),
          ),
          const SizedBox(height: 6),
          Text(
            _t(
              'Son onay süresi: ${preview.expiresAt.toLocal()}',
              'Confirmation expires: ${preview.expiresAt.toLocal()}',
            ),
            style: const TextStyle(color: CupertinoColors.secondaryLabel),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              CupertinoButton(
                onPressed: busy ? null : onDismiss,
                child: Text(_t('Kapat', 'Dismiss')),
              ),
              CupertinoButton.filled(
                onPressed: busy ? null : onConfirm,
                child: Text(_t('Devam et', 'Continue')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

final class _JobCard extends StatelessWidget {
  const _JobCard({
    required this.job,
    required this.bytes,
    required this.words,
    required this.turkish,
    required this.busy,
    required this.onRefresh,
    required this.onCancel,
    required this.onReconcile,
    required this.onCleanup,
  });
  final ServerMediaArchiveJob job;
  final String Function(int) bytes;
  final String Function(String) words;
  final bool turkish, busy;
  final VoidCallback onRefresh;
  final VoidCallback? onCancel, onReconcile, onCleanup;
  String _t(String tr, String en) => turkish ? tr : en;
  @override
  Widget build(BuildContext context) => _Card(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              job.kind == ServerMediaArchiveJobKind.optimize
                  ? CupertinoIcons.wand_stars
                  : CupertinoIcons.delete,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '${words(job.kind.name)} · ${words(job.state.name)}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Text(
              '#${job.revision}',
              style: const TextStyle(color: CupertinoColors.secondaryLabel),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _KeyValue(label: _t('Aşama', 'Phase'), value: words(job.phase)),
        _KeyValue(
          label: _t('Rezerv', 'Reserved'),
          value: bytes(job.reservedBytes),
        ),
        _KeyValue(
          label: _t('Orijinal', 'Original'),
          value: job.retainedOriginal
              ? _t('Korunuyor', 'Retained')
              : _t('Uygulanmaz', 'Not retained'),
        ),
        if (job.errorCode != null)
          Text(
            '${_t('Hata', 'Error')}: ${words(job.errorCode!)}',
            style: const TextStyle(color: CupertinoColors.systemRed),
          ),
        if (job.proofDigest != null)
          _KeyValue(
            label: _t('Doğrulama kanıtı', 'Verification proof'),
            value: '${job.proofDigest!.substring(0, 12)}…',
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          alignment: WrapAlignment.end,
          children: [
            CupertinoButton(
              onPressed: busy ? null : onRefresh,
              child: Text(_t('Yenile', 'Refresh')),
            ),
            if (onCancel != null)
              CupertinoButton(
                onPressed: busy ? null : onCancel,
                child: Text(_t('İptal et', 'Cancel')),
              ),
            if (onReconcile != null)
              CupertinoButton(
                onPressed: busy ? null : onReconcile,
                child: Text(_t('Uzlaştır', 'Reconcile')),
              ),
            if (onCleanup != null)
              CupertinoButton(
                onPressed: busy ? null : onCleanup,
                child: Text(_t('Orijinali temizle', 'Clean retained original')),
              ),
          ],
        ),
      ],
    ),
  );
}

final class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
  });
  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) => _Card(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon),
        const SizedBox(width: 10),
        Expanded(child: Text(message)),
        if (actionLabel != null)
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            onPressed: onAction,
            child: Text(actionLabel!),
          ),
      ],
    ),
  );
}

final class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.detail});
  final String title, detail;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 3),
      Text(
        detail,
        style: const TextStyle(color: CupertinoColors.secondaryLabel),
      ),
    ],
  );
}

final class _KeyValue extends StatelessWidget {
  const _KeyValue({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(color: CupertinoColors.secondaryLabel),
          ),
        ),
        const SizedBox(width: 12),
        Flexible(child: Text(value, textAlign: TextAlign.end)),
      ],
    ),
  );
}

final class _Card extends StatelessWidget {
  const _Card({required this.child, this.accent});
  final Widget child;
  final Color? accent;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: CupertinoDynamicColor.resolve(
        CupertinoColors.secondarySystemGroupedBackground,
        context,
      ),
      borderRadius: BorderRadius.circular(14),
      border: accent == null
          ? null
          : Border.all(
              color: CupertinoDynamicColor.resolve(accent!, context),
              width: 1.5,
            ),
    ),
    child: child,
  );
}
