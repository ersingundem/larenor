import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../data/camera_visual_sensor_controller.dart';
import '../domain/camera_visual_sensor_models.dart';

final class CameraVisualSensorStrings {
  const CameraVisualSensorStrings({
    required this.title,
    required this.refresh,
    required this.loading,
    required this.unavailable,
    required this.stale,
    required this.invalidScope,
    required this.noSensors,
    required this.engine,
    required this.detectorUnavailable,
    required this.unknown,
    required this.noTrustedFrame,
    required this.notAuthority,
    required this.architecture,
    required this.avx,
    required this.avx2,
    required this.supported,
    required this.unsupported,
    required this.notApplicable,
    required this.ready,
    required this.degraded,
    required this.on,
    required this.off,
    required this.confidence,
    required this.count,
    required this.observed,
    required this.model,
    required this.pipeline,
  });
  final String title, refresh, loading, unavailable, stale, invalidScope;
  final String noSensors, engine, detectorUnavailable, unknown, noTrustedFrame;
  final String notAuthority, architecture, avx, avx2;
  final String supported, unsupported, notApplicable;
  final String ready, degraded, on, off, confidence, count, observed;
  final String model, pipeline;

  static const en = CameraVisualSensorStrings(
    title: 'Camera visual sensors',
    refresh: 'Refresh sensor summary',
    loading: 'Loading visual sensor status…',
    unavailable: 'Visual sensor status is unavailable.',
    stale: 'This result belongs to an earlier session.',
    invalidScope: 'The result does not match this Core and home.',
    noSensors: 'No visual sensor rule is configured.',
    engine: 'Detector capability',
    detectorUnavailable: 'No trusted detector worker is configured.',
    unknown: 'Unknown',
    noTrustedFrame: 'No complete trusted frame has been evaluated.',
    notAuthority: 'This signal cannot unlock doors or prove identity.',
    architecture: 'Architecture',
    avx: 'AVX',
    avx2: 'AVX2',
    supported: 'Supported',
    unsupported: 'Unsupported or unknown',
    notApplicable: 'Not applicable',
    ready: 'Ready',
    degraded: 'Degraded',
    on: 'Detected',
    off: 'Not detected',
    confidence: 'Confidence',
    count: 'Count',
    observed: 'Observed',
    model: 'Model',
    pipeline: 'Pipeline',
  );

  static const tr = CameraVisualSensorStrings(
    title: 'Kamera görsel sensörleri',
    refresh: 'Sensör özetini yenile',
    loading: 'Görsel sensör durumu yükleniyor…',
    unavailable: 'Görsel sensör durumuna ulaşılamıyor.',
    stale: 'Bu sonuç önceki oturuma ait.',
    invalidScope: 'Sonuç bu Core ve evle eşleşmiyor.',
    noSensors: 'Yapılandırılmış görsel sensör kuralı yok.',
    engine: 'Algılama motoru yeteneği',
    detectorUnavailable: 'Güvenilir algılama workerı yapılandırılmadı.',
    unknown: 'Bilinmiyor',
    noTrustedFrame: 'Eksiksiz ve güvenilir bir kare değerlendirilmedi.',
    notAuthority: 'Bu sinyal kapı açamaz ve kimliği kanıtlayamaz.',
    architecture: 'Mimari',
    avx: 'AVX',
    avx2: 'AVX2',
    supported: 'Destekleniyor',
    unsupported: 'Desteklenmiyor veya bilinmiyor',
    notApplicable: 'Uygulanamaz',
    ready: 'Hazır',
    degraded: 'Bozulmuş',
    on: 'Algılandı',
    off: 'Algılanmadı',
    confidence: 'Güven',
    count: 'Sayı',
    observed: 'Gözlem',
    model: 'Model',
    pipeline: 'İşlem hattı',
  );
}

class CameraVisualSensorScreen extends StatefulWidget {
  const CameraVisualSensorScreen({
    super.key,
    required this.controller,
    required this.strings,
    this.sourceEditor,
    this.onSetup,
  });
  final Widget? sourceEditor;
  final VoidCallback? onSetup;
  final CameraVisualSensorController controller;
  final CameraVisualSensorStrings strings;

  @override
  State<CameraVisualSensorScreen> createState() =>
      _CameraVisualSensorScreenState();
}

class _CameraVisualSensorScreenState extends State<CameraVisualSensorScreen>
    with WidgetsBindingObserver {
  bool _foreground = true;
  bool get _current =>
      mounted &&
      _foreground &&
      TickerMode.valuesOf(context).enabled &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_changed);
    unawaited(widget.controller.refresh());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) widget.controller.retire();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_changed);
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppPageScaffold(
    navigationBar: CupertinoNavigationBar(
      middle: Text(widget.strings.title),
      trailing: widget.onSetup == null
          ? null
          : CupertinoButton(
              key: const ValueKey('visual-source-setup'),
              padding: EdgeInsets.zero,
              minimumSize: const Size(48, 48),
              onPressed: _current ? widget.onSetup : null,
              child: Icon(
                CupertinoIcons.slider_horizontal_3,
                semanticLabel:
                    Localizations.localeOf(context).languageCode == 'tr'
                    ? 'Kaynağı ayarla'
                    : 'Configure source',
              ),
            ),
    ),
    child: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 48),
          child: _body(
            (constraints.maxWidth - 48).clamp(0, double.infinity).toDouble(),
          ),
        ),
      ),
    ),
  );

  Widget _body(double width) {
    if (widget.sourceEditor != null) return widget.sourceEditor!;
    final controller = widget.controller;
    if (controller.busy && controller.value == null) {
      return _status(widget.strings.loading);
    }
    final failure = controller.failure;
    if (failure != null) {
      return _status(switch (failure) {
        CameraVisualSensorFailure.unavailable => widget.strings.unavailable,
        CameraVisualSensorFailure.staleAuthority => widget.strings.stale,
        CameraVisualSensorFailure.invalidScope => widget.strings.invalidScope,
      }, live: true);
    }
    final value = controller.value;
    if (value == null) return _status(widget.strings.unavailable);
    final columns = width >= 1000 ? 2 : 1;
    const gap = 20.0;
    final cardWidth = (width - gap * (columns - 1)) / columns;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Semantics(
            button: true,
            label: widget.strings.refresh,
            child: CupertinoButton(
              key: const ValueKey('visual-sensor-refresh'),
              autofocus: true,
              minimumSize: const Size(48, 48),
              onPressed: controller.busy || !_current
                  ? null
                  : controller.refresh,
              child: Text(widget.strings.refresh),
            ),
          ),
        ),
        const SizedBox(height: 12),
        _CapabilityCard(capability: value.capability, strings: widget.strings),
        const SizedBox(height: 20),
        if (value.sensors.isEmpty)
          _status(widget.strings.noSensors)
        else
          Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final sensor in value.sensors)
                SizedBox(
                  width: cardWidth,
                  child: _SensorCard(sensor: sensor, strings: widget.strings),
                ),
            ],
          ),
      ],
    );
  }

  Widget _status(String text, {bool live = false}) => Semantics(
    liveRegion: live,
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        text,
        style: AppText.emptyStateBody,
        textAlign: TextAlign.center,
      ),
    ),
  );
}

class _CapabilityCard extends StatelessWidget {
  const _CapabilityCard({required this.capability, required this.strings});
  final VisualEngineCapability capability;
  final CameraVisualSensorStrings strings;

  String _support(VisualCpuSupport value) => switch (value) {
    VisualCpuSupport.supported => strings.supported,
    VisualCpuSupport.notApplicable => strings.notApplicable,
    VisualCpuSupport.unsupported ||
    VisualCpuSupport.unknown => strings.unsupported,
  };

  String _detector() => switch (capability.detectorState) {
    VisualDetectorState.ready => strings.ready,
    VisualDetectorState.degraded => strings.degraded,
    VisualDetectorState.unavailable => strings.detectorUnavailable,
  };

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: '${strings.engine}. ${_detector()}',
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surface.resolveFrom(context),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(strings.engine, style: AppText.title2),
            const SizedBox(height: 8),
            Text(_detector(), style: AppText.body),
            const SizedBox(height: 12),
            Text(
              '${strings.architecture}: ${capability.architecture.name}',
              style: AppText.body,
            ),
            Text('${strings.avx}: ${_support(capability.avx)}'),
            Text('${strings.avx2}: ${_support(capability.avx2)}'),
          ],
        ),
      ),
    ),
  );
}

class _SensorCard extends StatelessWidget {
  const _SensorCard({required this.sensor, required this.strings});
  final CameraVisualSensor sensor;
  final CameraVisualSensorStrings strings;

  String get _state => switch (sensor.state) {
    VisualSensorState.on => strings.on,
    VisualSensorState.off => strings.off,
    VisualSensorState.unknown => strings.unknown,
  };

  String get _detail => switch (sensor.status) {
    VisualSensorStatus.ready =>
      '${strings.confidence}: ${(sensor.confidenceBps / 100).toStringAsFixed(1)}% · '
          '${strings.count}: ${sensor.count}',
    VisualSensorStatus.degraded => strings.degraded,
    VisualSensorStatus.unavailable => strings.noTrustedFrame,
  };

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: '${sensor.label}. $_state. $_detail. ${strings.notAuthority}',
    child: DecoratedBox(
      key: ValueKey('visual-sensor-${sensor.ruleId}'),
      decoration: BoxDecoration(
        color: AppColors.surface.resolveFrom(context),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: CupertinoColors.separator.resolveFrom(context),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(sensor.label, style: AppText.title2),
            const SizedBox(height: 8),
            Text(_state, style: AppText.headline),
            Text(_detail, style: AppText.body),
            if (sensor.observedAtMs case final observed?)
              Text(
                '${strings.observed}: '
                '${DateTime.fromMillisecondsSinceEpoch(observed, isUtc: true).toIso8601String()}',
                style: AppText.caption1,
              ),
            Text(
              '${strings.model}: ${sensor.modelId} · r${sensor.modelRevision}',
              style: AppText.caption1,
            ),
            Text(
              '${strings.pipeline}: ${sensor.pipelineId} · r${sensor.pipelineRevision}',
              style: AppText.caption1,
            ),
            const SizedBox(height: 8),
            Text(strings.notAuthority, style: AppText.caption1),
          ],
        ),
      ),
    ),
  );
}
