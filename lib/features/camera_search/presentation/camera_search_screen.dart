import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../data/camera_search_controller.dart';
import '../domain/camera_search_models.dart';

final class CameraSearchStrings {
  const CameraSearchStrings({
    required this.title,
    required this.hint,
    required this.search,
    required this.prompt,
    required this.loading,
    required this.empty,
    required this.unavailable,
    required this.invalidQuery,
    required this.stale,
    required this.localOnly,
    required this.semantic,
    required this.capturedAt,
    required this.camera,
    required this.cameraName,
  });

  final String title, hint, search, prompt, loading, empty, unavailable;
  final String invalidQuery, stale, localOnly, semantic, capturedAt, camera;
  final String cameraName;

  static const en = CameraSearchStrings(
    title: 'Camera recording search',
    hint: 'Describe an event, object or place',
    search: 'Search recordings',
    prompt: 'Search only the camera metadata available to this account.',
    loading: 'Searching authorized camera metadata…',
    empty: 'No authorized recordings matched this search.',
    unavailable: 'Camera search is unavailable.',
    invalidQuery: 'Enter at least two characters.',
    stale: 'These results belong to an earlier session. Search again.',
    localOnly: 'Local metadata results',
    semantic: 'Semantic-assisted results',
    capturedAt: 'Captured',
    camera: 'Camera',
    cameraName: 'Front door',
  );

  static const tr = CameraSearchStrings(
    title: 'Kamera kaydı arama',
    hint: 'Bir olayı, nesneyi veya yeri anlatın',
    search: 'Kayıtlarda ara',
    prompt: 'Yalnız bu hesabın erişebildiği kamera metadatasında arama yapın.',
    loading: 'Yetkili kamera metadatası aranıyor…',
    empty: 'Bu aramayla eşleşen yetkili kayıt bulunamadı.',
    unavailable: 'Kamera aramasına ulaşılamıyor.',
    invalidQuery: 'En az iki karakter girin.',
    stale: 'Bu sonuçlar önceki oturuma ait. Yeniden arayın.',
    localOnly: 'Yerel metadata sonuçları',
    semantic: 'Anlamsal destekli sonuçlar',
    capturedAt: 'Kayıt zamanı',
    camera: 'Kamera',
    cameraName: 'Ön kapı',
  );
}

class CameraSearchScreen extends StatefulWidget {
  const CameraSearchScreen({
    super.key,
    required this.controller,
    required this.strings,
    required this.filter,
    required this.cameraNames,
  });

  final CameraSearchController controller;
  final CameraSearchStrings strings;
  final CameraSearchFilter filter;
  final Map<String, String> cameraNames;

  @override
  State<CameraSearchScreen> createState() => _CameraSearchScreenState();
}

class _CameraSearchScreenState extends State<CameraSearchScreen>
    with WidgetsBindingObserver {
  final _query = TextEditingController();
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
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _search([String? value]) {
    if (!_current || widget.controller.busy) return;
    widget.controller.search(value ?? _query.text, widget.filter);
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
    _query.dispose();
    super.dispose();
  }

  String _failure(CameraSearchFailure failure) => switch (failure) {
    CameraSearchFailure.invalidQuery => widget.strings.invalidQuery,
    CameraSearchFailure.staleAuthority => widget.strings.stale,
    CameraSearchFailure.unavailable => widget.strings.unavailable,
  };

  @override
  Widget build(BuildContext context) => AppPageScaffold(
    navigationBar: CupertinoNavigationBar(middle: Text(widget.strings.title)),
    child: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.enter): _search,
              },
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: CupertinoSearchTextField(
                      key: const ValueKey('camera-search-field'),
                      controller: _query,
                      autofocus: true,
                      placeholder: widget.strings.hint,
                      onSubmitted: _search,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Semantics(
                    button: true,
                    label: widget.strings.search,
                    child: CupertinoButton.filled(
                      key: const ValueKey('camera-search-submit'),
                      minimumSize: const Size(48, 48),
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      onPressed: widget.controller.busy || !_current
                          ? null
                          : _search,
                      child: const Icon(CupertinoIcons.search),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(child: _body()),
        ],
      ),
    ),
  );

  Widget _body() {
    final controller = widget.controller;
    if (controller.busy) {
      return _Status(text: widget.strings.loading, loading: true);
    }
    if (controller.failure case final failure?) {
      return _Status(text: _failure(failure), live: true);
    }
    if (!controller.searched) return _Status(text: widget.strings.prompt);
    if (controller.results.isEmpty) return _Status(text: widget.strings.empty);
    final local = controller.page!.mode == CameraSearchMode.localMetadata;
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = (constraints.maxWidth - 48).clamp(0, double.infinity);
        final columns = available >= 1000 ? 2 : 1;
        final width = (available - (columns - 1) * 20) / columns;
        return ListView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 48),
          children: [
            Semantics(
              liveRegion: true,
              child: Text(
                local ? widget.strings.localOnly : widget.strings.semantic,
                style: AppText.headline,
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 20,
              runSpacing: 20,
              children: [
                for (final result in controller.results)
                  SizedBox(
                    width: width,
                    child: _ResultCard(
                      key: ValueKey(
                        'camera-result-${result.evidence.clipId[0]}',
                      ),
                      result: result,
                      cameraName:
                          widget.cameraNames[result.evidence.cameraId] ??
                          widget.strings.camera,
                      strings: widget.strings,
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _Status extends StatelessWidget {
  const _Status({required this.text, this.loading = false, this.live = false});
  final String text;
  final bool loading, live;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: live,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading) ...[
              const CupertinoActivityIndicator(),
              const SizedBox(height: 16),
            ],
            Text(
              text,
              style: AppText.emptyStateBody,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    ),
  );
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({
    super.key,
    required this.result,
    required this.cameraName,
    required this.strings,
  });
  final CameraSearchMatch result;
  final String cameraName;
  final CameraSearchStrings strings;

  String _time(DateTime value) {
    final local = value.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(local.day)}.${two(local.month)}.${local.year} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: AppColors.surface.resolveFrom(context),
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: CupertinoColors.separator.resolveFrom(context)),
    ),
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(result.summary, style: AppText.title3),
          const SizedBox(height: 14),
          _Line(
            icon: CupertinoIcons.video_camera,
            text: '${strings.camera}: $cameraName',
          ),
          _Line(
            icon: CupertinoIcons.clock,
            text: '${strings.capturedAt}: ${_time(result.evidence.capturedAt)}',
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final term in result.matchedTerms)
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: CupertinoColors.systemGrey5.resolveFrom(context),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    child: Text(term, style: AppText.footnote),
                  ),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 22),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: AppText.body)),
      ],
    ),
  );
}
