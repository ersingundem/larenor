import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../data/core_catalog_playback_capability_adapter.dart';
import '../domain/core_catalog_player_binding.dart';

final class _PanelDeadlineCancelled implements Exception {
  const _PanelDeadlineCancelled();
}

final class _OwnedPanelDeadline<T> {
  _OwnedPanelDeadline(Future<T> operation, Duration timeout) {
    _timer = Timer(timeout, () {
      if (!_result.isCompleted) {
        _result.completeError(TimeoutException('quality request timed out'));
      }
    });
    operation.then(
      (value) {
        _timer.cancel();
        if (!_result.isCompleted) _result.complete(value);
      },
      onError: (Object error, StackTrace stackTrace) {
        _timer.cancel();
        if (!_result.isCompleted) _result.completeError(error, stackTrace);
      },
    );
  }

  final Completer<T> _result = Completer<T>();
  late final Timer _timer;

  Future<T> get future => _result.future;

  void cancel() {
    _timer.cancel();
    if (!_result.isCompleted) {
      _result.completeError(const _PanelDeadlineCancelled());
    }
  }
}

/// Read-only, short-lived quality advice for one exact verified-Core catalog
/// binding. This panel never creates or consumes a playback lease.
final class CoreCatalogPlaybackQualityPanel extends StatefulWidget {
  const CoreCatalogPlaybackQualityPanel({
    super.key,
    required this.adapter,
    required this.binding,
    required this.current,
  });

  final CoreCatalogPlaybackCapabilityAdapter adapter;
  final CoreCatalogPlayerBinding binding;
  final bool Function() current;

  @override
  State<CoreCatalogPlaybackQualityPanel> createState() =>
      _CoreCatalogPlaybackQualityPanelState();
}

final class _CoreCatalogPlaybackQualityPanelState
    extends State<CoreCatalogPlaybackQualityPanel>
    with WidgetsBindingObserver {
  static const _requestTimeout = Duration(seconds: 10);
  CoreCatalogPlaybackAssessment? _assessment;
  Timer? _expiry;
  _OwnedPanelDeadline<CoreCatalogPlaybackAssessment?>? _loadDeadline;
  _OwnedPanelDeadline<bool>? _revalidationDeadline;
  int _generation = 0;
  bool _loading = false;
  bool _paused = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.adapter.addAuthorityListener(_authorityChanged);
    unawaited(_load());
  }

  @override
  void didUpdateWidget(CoreCatalogPlaybackQualityPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.adapter, widget.adapter)) {
      oldWidget.adapter.removeAuthorityListener(_authorityChanged);
      widget.adapter.addAuthorityListener(_authorityChanged);
    }
    if (!widget.current()) {
      _invalidate();
      return;
    }
    if (!identical(oldWidget.adapter, widget.adapter) ||
        !identical(oldWidget.binding, widget.binding)) {
      _invalidate();
      unawaited(_load());
    }
  }

  void _authorityChanged() {
    final retained = _assessment;
    if (retained == null || _paused) return;
    _cancelRevalidationDeadline();
    final generation = _generation;
    final deadline = _OwnedPanelDeadline(
      widget.adapter.revalidateAssessment(retained, current: widget.current),
      _requestTimeout,
    );
    _revalidationDeadline = deadline;
    unawaited(() async {
      var valid = false;
      try {
        valid = await deadline.future;
      } on _PanelDeadlineCancelled {
        return;
      } catch (_) {
        valid = false;
      } finally {
        if (identical(_revalidationDeadline, deadline)) {
          _revalidationDeadline = null;
        }
      }
      if (!mounted ||
          generation != _generation ||
          !identical(retained, _assessment)) {
        return;
      }
      if (!valid) _invalidate(notify: true);
    }());
  }

  Future<void> _load() async {
    if (_paused || _loading || !widget.current()) return;
    _cancelLoadDeadline();
    _cancelRevalidationDeadline();
    final generation = ++_generation;
    _expiry?.cancel();
    setState(() {
      _assessment = null;
      _loading = true;
    });
    CoreCatalogPlaybackAssessment? assessment;
    final deadline = _OwnedPanelDeadline(
      widget.adapter.assess(widget.binding, current: widget.current),
      _requestTimeout,
    );
    _loadDeadline = deadline;
    try {
      assessment = await deadline.future;
    } on _PanelDeadlineCancelled {
      return;
    } catch (_) {
      assessment = null;
    } finally {
      if (identical(_loadDeadline, deadline)) _loadDeadline = null;
    }
    if (!mounted || generation != _generation || _paused) return;
    if (assessment == null || !widget.current()) {
      setState(() {
        _loading = false;
      });
      return;
    }
    final remaining = widget.adapter.remaining(assessment);
    if (remaining <= Duration.zero) {
      setState(() {
        _loading = false;
      });
      return;
    }
    setState(() {
      _assessment = assessment;
      _loading = false;
    });
    _expiry = Timer(remaining, () {
      if (!mounted || generation != _generation) return;
      _invalidate(notify: true);
    });
  }

  void _invalidate({bool notify = false}) {
    _cancelLoadDeadline();
    _cancelRevalidationDeadline();
    _generation++;
    _expiry?.cancel();
    _expiry = null;
    _assessment = null;
    _loading = false;
    if (notify && mounted) setState(() {});
  }

  void _cancelLoadDeadline() {
    _loadDeadline?.cancel();
    _loadDeadline = null;
  }

  void _cancelRevalidationDeadline() {
    _revalidationDeadline?.cancel();
    _revalidationDeadline = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _paused = state != AppLifecycleState.resumed;
    if (_paused) {
      _invalidate(notify: true);
    } else {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _generation++;
    _cancelLoadDeadline();
    _cancelRevalidationDeadline();
    _expiry?.cancel();
    widget.adapter.removeAuthorityListener(_authorityChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final copy = _QualityCopy.of(context);
    if (_loading) {
      return Semantics(
        key: const ValueKey('quality-loading'),
        label: copy.loading,
        liveRegion: true,
        child: const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CupertinoActivityIndicator()),
        ),
      );
    }
    final assessment = _assessment;
    if (assessment == null) {
      return Semantics(
        liveRegion: true,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(copy.failure, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              CupertinoButton(
                key: const ValueKey('quality-retry'),
                onPressed: _paused || !widget.current() ? null : _load,
                child: Text(copy.retry),
              ),
            ],
          ),
        ),
      );
    }
    return _AssessmentView(assessment: assessment, copy: copy);
  }
}

final class _AssessmentView extends StatelessWidget {
  const _AssessmentView({required this.assessment, required this.copy});

  final CoreCatalogPlaybackAssessment assessment;
  final _QualityCopy copy;

  @override
  Widget build(BuildContext context) {
    final source = assessment.source;
    final transcoding = assessment.transcoding;
    final observed = <String>[
      if (source?.container != null) source!.container!.toUpperCase(),
      ...?source?.videoCodecs.map(_codec),
      ...?source?.audioCodecs.map(_codec),
      ...?source?.videoRanges,
    ];
    final profile = assessment.profile;
    return Semantics(
      container: true,
      label: copy.summary(assessment.outcome),
      child: CupertinoListSection.insetGrouped(
        key: const ValueKey('quality-assessment'),
        header: Text(copy.title),
        footer: Text(copy.boundary),
        children: [
          _row(copy.result, copy.summary(assessment.outcome)),
          _row(
            copy.providerFacts,
            observed.isEmpty ? copy.notReported : observed.join(' · '),
          ),
          _row(
            copy.sourceBitrate,
            source?.bitrateBps == null
                ? copy.notReported
                : _bitrate(source!.bitrateBps!),
          ),
          if (transcoding != null)
            _row(
              copy.transcoding,
              [
                if (transcoding.container != null)
                  transcoding.container!.toUpperCase(),
                if (transcoding.videoCodec != null)
                  _codec(transcoding.videoCodec!),
                if (transcoding.audioCodec != null)
                  _codec(transcoding.audioCodec!),
                if (transcoding.bitrateBps != null)
                  _bitrate(transcoding.bitrateBps!),
              ].join(' · '),
            ),
          _row(
            copy.nativeProfile,
            '${profile.maxWidth} × ${profile.maxHeight} · '
            '${profile.videoCodecs.map(_codec).join(', ')} · '
            '${profile.audioCodecs.map(_codec).join(', ')}',
          ),
          _row(copy.policyCeiling, _bitrate(profile.maxStreamingBitrateBps)),
          _row(copy.recommendation, copy.recommendationFor(assessment)),
        ],
      ),
    );
  }

  CupertinoListTile _row(String title, String value) =>
      CupertinoListTile(title: Text(title), subtitle: Text(value));
}

String _bitrate(int value) => '${(value / 1000000).toStringAsFixed(1)} Mbps';

String _codec(String value) => switch (value.toLowerCase()) {
  'h264' => 'H.264',
  'h265' || 'hevc' => 'HEVC',
  'aac' => 'AAC',
  'eac3' => 'E-AC-3',
  'ac3' => 'AC-3',
  'av1' => 'AV1',
  'vp8' => 'VP8',
  'vp9' => 'VP9',
  _ => value.toUpperCase(),
};

final class _QualityCopy {
  const _QualityCopy(this.tr);
  factory _QualityCopy.of(BuildContext context) =>
      _QualityCopy(Localizations.localeOf(context).languageCode == 'tr');

  final bool tr;
  String get title => tr ? 'Oynatma kalitesi' : 'Playback quality';
  String get loading =>
      tr ? 'Kalite bilgisi yükleniyor' : 'Loading quality advice';
  String get failure =>
      tr ? 'Kalite bilgisi alınamadı' : 'Quality advice is unavailable';
  String get retry => tr ? 'Yeniden dene' : 'Retry';
  String get result => tr ? 'Sonuç' : 'Result';
  String get providerFacts => tr ? 'Kaynak bilgileri' : 'Observed source';
  String get sourceBitrate => tr ? 'Kaynak bit hızı' : 'Source bitrate';
  String get transcoding => tr ? 'Dönüştürme' : 'Transcoding';
  String get nativeProfile => tr ? 'Bu cihaz profili' : 'This device profile';
  String get policyCeiling => tr ? 'Politika üst sınırı' : 'Policy ceiling';
  String get recommendation => tr ? 'Öneri' : 'Recommendation';
  String get notReported => tr ? 'Bildirilmedi' : 'Not reported';
  String get boundary => tr
      ? 'Ağ bant genişliği ölçülmedi. HDR, donanım hızlandırma ve fiziksel oynatma doğrulaması manuel kalır.'
      : 'Network bandwidth is not measured. HDR, hardware acceleration and physical playback acceptance remain manual.';

  String summary(CoreCatalogPlaybackOutcome outcome) => switch (outcome) {
    CoreCatalogPlaybackOutcome.directPlaySupported =>
      tr ? 'Doğrudan Oynatma uygun' : 'Direct Play is suitable',
    CoreCatalogPlaybackOutcome.requiresRemux =>
      tr ? 'Kapsayıcı dönüşümü gerekli' : 'Remux is advised',
    CoreCatalogPlaybackOutcome.requiresTranscode =>
      tr ? 'Kod dönüştürme gerekli' : 'Transcoding advised',
    CoreCatalogPlaybackOutcome.unavailable =>
      tr ? 'Uyumlu yöntem bulunamadı' : 'No compatible method',
    CoreCatalogPlaybackOutcome.contractUnknown =>
      tr ? 'Uyumluluk bilinmiyor' : 'Compatibility is unknown',
  };

  String recommendationFor(
    CoreCatalogPlaybackAssessment assessment,
  ) => switch (assessment.outcome) {
    CoreCatalogPlaybackOutcome.directPlaySupported =>
      tr
          ? 'Özgün baytlar bu bildirilen profil için kullanılabilir; fiziksel sonuç garanti edilmez.'
          : 'Original bytes are eligible for this reported profile; physical playback is not guaranteed.',
    CoreCatalogPlaybackOutcome.requiresRemux =>
      tr
          ? 'Sunucu akışı yeniden paketlemelidir; özgün bayt oynatma yetkisi verilmez.'
          : 'The server must repackage the stream; original-byte playback is not authorized.',
    CoreCatalogPlaybackOutcome.requiresTranscode =>
      tr
          ? 'Sunucu dönüştürmesi gerekir; kalite ve gecikme fiziksel olarak doğrulanmadı.'
          : 'Server transcoding is required; quality and latency are not physically validated.',
    CoreCatalogPlaybackOutcome.unavailable =>
      tr
          ? 'Bu profil için desteklenen bir oynatma yöntemi yok.'
          : 'No supported playback method was reported for this profile.',
    CoreCatalogPlaybackOutcome.contractUnknown =>
      tr ? 'Kaynak seçimi veya sağlayıcı sözleşmesi kesin bir öneri vermedi.' : 'Source selection or the provider contract did not yield a definite recommendation.',
  };
}
