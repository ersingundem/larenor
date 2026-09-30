import 'dart:async';
import 'dart:math';

import 'package:flutter/cupertino.dart';

import '../../../shared/theme/typography.dart';
import '../data/camera_visual_sensor_source_api.dart';

/// Inline setup keeps the parent route's authority active while editing.
final class CameraVisualSourceEditor extends StatefulWidget {
  const CameraVisualSourceEditor({
    super.key,
    required this.gateway,
    required this.isCurrent,
    required this.onClose,
  });
  final VisualSourceGateway gateway;
  final bool Function() isCurrent;
  final VoidCallback onClose;
  @override
  State<CameraVisualSourceEditor> createState() =>
      _CameraVisualSourceEditorState();
}

final class _CameraVisualSourceEditorState
    extends State<CameraVisualSourceEditor> {
  VisualSourceCatalog? _catalog;
  List<VisualSourceModel> _models = const [];
  VisualSourceBinding? _binding;
  VisualSourceCamera? _camera;
  VisualSourceModel? _model;
  String? _label, _error;
  bool _busy = false, _advanced = false;
  int _epoch = 0;
  double _confidence = 90, _hold = 2, _clear = 2, _retention = 30;
  bool get _tr => Localizations.localeOf(context).languageCode == 'tr';
  bool get _current {
    try {
      return mounted && widget.isCurrent();
    } catch (_) {
      return false;
    }
  }

  String _text(String en, String tr) => _tr ? tr : en;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _epoch++;
    super.dispose();
  }

  Future<void> _run(Future<void> Function(int) operation) async {
    if (_busy || !_current) return;
    final epoch = ++_epoch;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation(epoch);
    } catch (_) {
      if (_current && epoch == _epoch) {
        setState(
          () => _error = _text(
            'The source changed or is unavailable. Reload and try again.',
            'Kaynak değişti veya kullanılamıyor. Yenileyip tekrar deneyin.',
          ),
        );
      }
    } finally {
      if (_current && epoch == _epoch) setState(() => _busy = false);
    }
  }

  Future<void> _load() => _run((epoch) async {
    final catalog = await widget.gateway.load();
    if (!_current || epoch != _epoch) return;
    setState(() {
      _catalog = catalog;
      _camera = null;
      _model = null;
      _label = null;
      _models = const [];
      _binding = null;
    });
  });
  Future<void> _select(
    VisualSourceCamera camera, {
    VisualSourceBinding? binding,
  }) => _run((epoch) async {
    final models = await widget.gateway.models(
      camera.id,
      _catalog!.sourceRevision,
    );
    if (!_current || epoch != _epoch) return;
    setState(() {
      _camera = camera;
      _models = models;
      _binding = binding;
      _model = null;
      _label = null;
      if (binding != null) {
        for (final model in models) {
          if (model.name == binding.model &&
              model.labels.contains(binding.label)) {
            _model = model;
            _label = binding.label;
          }
        }
        _confidence = binding.confidenceBps / 100;
        _hold = binding.holdMs / 1000;
        _clear = binding.clearMs / 1000;
        _retention = binding.retentionMs / 1000;
      } else {
        _confidence = 90;
        _hold = 2;
        _clear = 2;
        _retention = 30;
      }
    });
  });
  Future<void> _save() => _run((epoch) async {
    final random = Random.secure();
    final id =
        _binding?.ruleId ??
        List.generate(
          16,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
    await widget.gateway.save(
      ruleId: id,
      revision: _binding?.revision ?? 0,
      cameraId: _camera!.id,
      model: _model!.name,
      label: _label!,
      confidenceBps: (_confidence * 100).round(),
      holdMs: (_hold * 1000).round(),
      clearMs: (_clear * 1000).round(),
      retentionMs: (_retention * 1000).round(),
    );
    if (_current && epoch == _epoch) widget.onClose();
  });
  Widget _button(
    String text,
    VoidCallback action, {
    bool selected = false,
    Key? key,
  }) => CupertinoButton(
    key: key,
    minimumSize: const Size(48, 48),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    onPressed: _busy || !_current ? null : action,
    child: Row(
      children: [
        Expanded(child: Text(text)),
        if (selected) const Icon(CupertinoIcons.check_mark),
      ],
    ),
  );
  Widget _slider(
    String title,
    double value,
    double min,
    double max,
    ValueChanged<double> changed,
    String suffix,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('$title: ${value.toStringAsFixed(0)}$suffix', style: AppText.body),
      Semantics(
        label: title,
        child: CupertinoSlider(
          value: value,
          min: min,
          max: max,
          onChanged: _busy || !_current
              ? null
              : (v) => setState(() => changed(v)),
        ),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) {
    final catalog = _catalog;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _button(
          _text('Back to sensors', 'Sensörlere dön'),
          widget.onClose,
          key: const ValueKey('visual-source-close'),
        ),
        Text(
          _text('Connect a trained model', 'Eğitilmiş model bağla'),
          style: AppText.title2,
        ),
        const SizedBox(height: 12),
        Text(
          _text(
            'First configure a single-camera state model and train it in Frigate 0.17. Training requires AVX and AVX2 on the Frigate host. Core verifies a new classified image; an old or missing image stays unknown.',
            'Önce Frigate 0.17 üzerinde tek kameraya bağlı durum modelini kurup eğitin. Eğitim Frigate sunucusunda AVX ve AVX2 ister. Core yeni sınıflandırılmış kareyi doğrular; eski veya eksik kare bilinmiyor kalır.',
          ),
          style: AppText.body,
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.all(16),
            child: CupertinoActivityIndicator(),
          ),
        if (_error != null)
          Semantics(
            liveRegion: true,
            child: Text(_error!, style: AppText.body),
          ),
        _button(
          _text('Reload sources', 'Kaynakları yenile'),
          () => unawaited(_load()),
          key: const ValueKey('visual-source-reload'),
        ),
        if (catalog != null) ...[
          if (!catalog.decoderAvailable)
            Text(
              _text(
                'Install FFmpeg and FFprobe on Core to verify actual images.',
                'Gerçek kareleri doğrulamak için Core üzerinde FFmpeg ve FFprobe kurulmalı.',
              ),
            ),
          if (catalog.sourceRevision == 0)
            Text(
              _text(
                'Connect Frigate in camera search first.',
                'Önce kamera araması ayarlarından Frigate kaynağını bağlayın.',
              ),
            ),
          if (catalog.bindings.isNotEmpty) ...[
            Text(
              _text('Existing sensors', 'Mevcut sensörler'),
              style: AppText.headline,
            ),
            for (final binding in catalog.bindings)
              _button('${binding.model} · ${binding.label}', () {
                for (final camera in catalog.cameras) {
                  if (camera.id == binding.cameraId) {
                    unawaited(_select(camera, binding: binding));
                    return;
                  }
                }
                setState(
                  () => _error = _text(
                    'The original camera is no longer available.',
                    'Önceki kamera artık kullanılamıyor.',
                  ),
                );
              }, selected: _binding?.ruleId == binding.ruleId),
          ],
          Text(_text('Camera', 'Kamera'), style: AppText.headline),
          if (catalog.cameras.isEmpty)
            Text(
              _text(
                'No permitted camera is available.',
                'İzinli kamera bulunamadı.',
              ),
            ),
          if (catalog.sourceRevision > 0)
            for (final camera in catalog.cameras)
              _button(
                camera.name,
                () => unawaited(_select(camera)),
                selected: _camera?.id == camera.id,
              ),
          if (_camera != null) ...[
            Text(
              _text('Trained model', 'Eğitilmiş model'),
              style: AppText.headline,
            ),
            if (_models.isEmpty)
              Text(
                _text(
                  'No trained single-camera model matches this camera. Configure and train it in Frigate, then reload.',
                  'Bu kamera için eğitilmiş tek kamera modeli yok. Frigate üzerinde kurup eğitin ve yenileyin.',
                ),
              ),
            for (final model in _models)
              _button(
                model.name,
                () => setState(() {
                  _model = model;
                  _label = null;
                }),
                selected: _model == model,
              ),
          ],
          if (_model != null) ...[
            Text(
              _text('Detected state', 'Algılanacak durum'),
              style: AppText.headline,
            ),
            for (final label in _model!.labels)
              _button(
                label,
                () => setState(() => _label = label),
                selected: _label == label,
              ),
            _slider(
              _text('Minimum confidence', 'En az güven'),
              _confidence,
              1,
              100,
              (v) => _confidence = v,
              '%',
            ),
            _button(
              _text('Timing and freshness', 'Zamanlama ve tazelik'),
              () => setState(() => _advanced = !_advanced),
            ),
            if (_advanced) ...[
              _slider(
                _text('Hold before detecting', 'Algılama öncesi bekleme'),
                _hold,
                0,
                60,
                (v) => _hold = v,
                ' s',
              ),
              _slider(
                _text(
                  'Clear after other state',
                  'Diğer durum sonrası sıfırlama',
                ),
                _clear,
                0,
                300,
                (v) => _clear = v,
                ' s',
              ),
              _slider(
                _text('Maximum image age', 'En eski kare yaşı'),
                _retention,
                1,
                300,
                (v) => _retention = v,
                ' s',
              ),
            ],
          ],
          const SizedBox(height: 16),
          CupertinoButton.filled(
            key: const ValueKey('visual-source-save'),
            minimumSize: const Size(48, 48),
            onPressed:
                _busy ||
                    !_current ||
                    !catalog.decoderAvailable ||
                    _camera == null ||
                    _model == null ||
                    _label == null
                ? null
                : () => unawaited(_save()),
            child: Text(_text('Save visual sensor', 'Görsel sensörü kaydet')),
          ),
        ],
      ],
    );
  }
}
