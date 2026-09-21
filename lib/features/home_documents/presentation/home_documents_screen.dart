import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../data/home_document_controller.dart';
import '../domain/home_document_models.dart';

class HomeDocumentsScreen extends StatefulWidget {
  const HomeDocumentsScreen({
    super.key,
    required this.controller,
    this.readers = const [],
    this.autoLoad = true,
  });
  final HomeDocumentController controller;
  final List<HomeDocumentReader> readers;
  final bool autoLoad;

  @override
  State<HomeDocumentsScreen> createState() => _HomeDocumentsScreenState();
}

class _HomeDocumentsScreenState extends State<HomeDocumentsScreen>
    with WidgetsBindingObserver {
  final _title = TextEditingController();
  final _inventory = TextEditingController();
  final _resource = TextEditingController();
  final _warranty = TextEditingController();
  final _titleFocus = FocusNode();
  final _inventoryFocus = FocusNode();
  final _resourceFocus = FocusNode();
  final _warrantyFocus = FocusNode();
  final _readers = <String>{};
  HomeDocumentUploadEvidence? _seenUpload;
  HomeDocumentKind _kind = HomeDocumentKind.invoice;
  bool _confirmWarranty = false;
  bool _lifecycleActive = true, _routeActive = true;
  bool? _lastRouteActive;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_changed);
    if (widget.autoLoad) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.controller.load();
      });
    }
  }

  void _changed() {
    if (!mounted) return;
    final upload = widget.controller.upload;
    if (upload != null && !identical(upload, _seenUpload)) {
      _seenUpload = upload;
      if (_title.text.isEmpty) {
        final separator = upload.filename.lastIndexOf('.');
        _title.text = separator > 0
            ? upload.filename.substring(0, separator)
            : upload.filename;
      }
      _warranty.text = upload.candidate?.extractedDate ?? '';
      _confirmWarranty = false;
    }
    setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active =
        (ModalRoute.isCurrentOf(context) ?? true) &&
        TickerMode.valuesOf(context).enabled;
    if (_lastRouteActive == active) return;
    _lastRouteActive = active;
    _routeActive = active;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.controller.setActive(_lifecycleActive && _routeActive);
      if (_lifecycleActive && _routeActive && widget.autoLoad) {
        widget.controller.load();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleActive = state == AppLifecycleState.resumed;
    widget.controller.setActive(_lifecycleActive && _routeActive);
    if (_lifecycleActive && _routeActive && widget.autoLoad) {
      widget.controller.load();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_changed);
    widget.controller.setActive(false);
    _title.dispose();
    _inventory.dispose();
    _resource.dispose();
    _warranty.dispose();
    _titleFocus.dispose();
    _inventoryFocus.dispose();
    _resourceFocus.dispose();
    _warrantyFocus.dispose();
    super.dispose();
  }

  Future<void> _publish() async {
    await widget.controller.publish(
      title: _title.text.trim(),
      kind: _kind,
      inventoryItemId: _inventory.text.trim(),
      readerIds: _readers.toList()..sort(),
      confirmWarranty: _confirmWarranty,
      warrantyDate: _warranty.text.trim().isEmpty
          ? null
          : _warranty.text.trim(),
    );
    if (mounted && widget.controller.failure == null) {
      _title.clear();
      _inventory.clear();
      _resource.clear();
      _warranty.clear();
      _readers.clear();
      _confirmWarranty = false;
      _seenUpload = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final copy = _Copy.of(context);
    final failure = switch (widget.controller.failure) {
      HomeDocumentFailure.offline => copy.offline,
      HomeDocumentFailure.stale => copy.stale,
      HomeDocumentFailure.rejected => copy.rejected,
      HomeDocumentFailure.invalidResponse => copy.invalidResponse,
      HomeDocumentFailure.invalidInput => copy.invalidInput,
      null => null,
    };
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(copy.title)),
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final editor = _editor(copy);
            final library = _library(copy);
            return SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1180),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (failure != null)
                        Semantics(liveRegion: true, child: _Notice(failure))
                      else if (widget.controller.busy)
                        Semantics(
                          liveRegion: true,
                          label: copy.loading,
                          child: const Padding(
                            padding: EdgeInsets.only(bottom: 12),
                            child: CupertinoActivityIndicator(),
                          ),
                        ),
                      if (constraints.maxWidth >= 900)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (widget.controller.isAdmin) ...[
                              Expanded(child: editor),
                              const SizedBox(width: 20),
                            ],
                            Expanded(flex: 2, child: library),
                          ],
                        )
                      else ...[
                        if (widget.controller.isAdmin) ...[
                          editor,
                          const SizedBox(height: 20),
                        ],
                        library,
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _editor(_Copy copy) {
    final upload = widget.controller.upload;
    final candidate = upload?.candidate;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(header: true, child: Text(copy.add, style: _heading)),
          const SizedBox(height: 12),
          _field(
            key: const ValueKey('home-doc-resource'),
            controller: _resource,
            focus: _resourceFocus,
            label: copy.resourceId,
            action: TextInputAction.done,
            onSubmitted: (_) {
              if (widget.controller.canUpload) {
                unawaited(widget.controller.stageUpload(_resource.text.trim()));
              }
            },
            max: 32,
          ),
          const SizedBox(height: 12),
          _semanticButton(
            key: const ValueKey('home-doc-upload'),
            label: copy.upload,
            enabled: widget.controller.canUpload,
            onPressed: () =>
                widget.controller.stageUpload(_resource.text.trim()),
            child: Text(copy.upload),
          ),
          if (upload != null) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text('${copy.uploaded}: ${upload.filename}'),
            ),
            if (candidate != null) ...[
              const SizedBox(height: 8),
              _Notice(
                '${copy.ocrSuggestion}: ${candidate.extractedDate} · ${(candidate.confidencePermille / 10).toStringAsFixed(0)}%',
              ),
            ],
          ],
          const SizedBox(height: 12),
          _field(
            key: const ValueKey('home-doc-title'),
            controller: _title,
            focus: _titleFocus,
            label: copy.documentTitle,
            action: TextInputAction.next,
            onSubmitted: (_) => _inventoryFocus.requestFocus(),
            max: 120,
          ),
          const SizedBox(height: 12),
          Semantics(
            label: copy.documentKind,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: HomeDocumentKind.values
                  .map(
                    (kind) => CupertinoButton(
                      key: ValueKey('home-doc-kind-${kind.name}'),
                      minimumSize: const Size(48, 48),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      color: _kind == kind
                          ? CupertinoColors.activeBlue
                          : CupertinoColors.systemGrey5.resolveFrom(context),
                      onPressed: widget.controller.busy
                          ? null
                          : () => setState(() => _kind = kind),
                      child: Text(copy.kind(kind)),
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
          const SizedBox(height: 12),
          _field(
            key: const ValueKey('home-doc-inventory'),
            controller: _inventory,
            focus: _inventoryFocus,
            label: copy.inventoryId,
            action: TextInputAction.next,
            onSubmitted: (_) => _warrantyFocus.requestFocus(),
            max: 32,
          ),
          const SizedBox(height: 12),
          _field(
            key: const ValueKey('home-doc-warranty'),
            controller: _warranty,
            focus: _warrantyFocus,
            label: copy.warrantyDate,
            action: TextInputAction.done,
            onSubmitted: (_) {
              if (widget.controller.canPublish) unawaited(_publish());
            },
            max: 10,
          ),
          const SizedBox(height: 8),
          Semantics(
            toggled: _confirmWarranty,
            label: copy.confirmWarranty,
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 10,
              children: [
                CupertinoSwitch(
                  key: const ValueKey('home-doc-confirm-warranty'),
                  value: _confirmWarranty,
                  onChanged: upload == null
                      ? null
                      : (value) => setState(() => _confirmWarranty = value),
                ),
                Text(copy.confirmWarranty),
              ],
            ),
          ),
          if (widget.readers.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(copy.privateReaders),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: widget.readers
                  .map(
                    (reader) => CupertinoButton(
                      key: ValueKey('home-doc-reader-${reader.id}'),
                      minimumSize: const Size(48, 48),
                      color: _readers.contains(reader.id)
                          ? CupertinoColors.activeBlue
                          : CupertinoColors.systemGrey5.resolveFrom(context),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      onPressed: widget.controller.busy
                          ? null
                          : () => setState(() {
                              if (!_readers.add(reader.id)) {
                                _readers.remove(reader.id);
                              }
                            }),
                      child: Text(reader.label),
                    ),
                  )
                  .toList(growable: false),
            ),
          ],
          const SizedBox(height: 16),
          _semanticButton(
            key: const ValueKey('home-doc-publish'),
            label: copy.publish,
            enabled: widget.controller.canPublish,
            onPressed: _publish,
            filled: true,
            child: Text(copy.publish),
          ),
        ],
      ),
    );
  }

  Widget _library(_Copy copy) {
    final items = widget.controller.page?.items ?? const <HomeDocument>[];
    final reminders =
        widget.controller.reminderPage?.items ?? const <HomeWarrantyReminder>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(copy.library, style: _heading),
                    ),
                  ),
                  CupertinoButton(
                    key: const ValueKey('home-doc-refresh'),
                    minimumSize: const Size.square(48),
                    padding: EdgeInsets.zero,
                    onPressed: widget.controller.busy
                        ? null
                        : widget.controller.load,
                    child: Semantics(
                      label: copy.refresh,
                      child: const Icon(CupertinoIcons.refresh),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (items.isEmpty)
                Text(copy.empty)
              else
                ...items.map((item) => _DocumentRow(item: item, copy: copy)),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                header: true,
                child: Text(copy.reminders, style: _heading),
              ),
              const SizedBox(height: 8),
              if (reminders.isEmpty)
                Text(copy.noReminders)
              else
                ...reminders.map(
                  (item) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      '${item.title} · ${item.expiresOn}',
                      key: ValueKey('home-doc-reminder-${item.documentId}'),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _field({
    required Key key,
    required TextEditingController controller,
    required FocusNode focus,
    required String label,
    required TextInputAction action,
    required ValueChanged<String> onSubmitted,
    required int max,
  }) => Semantics(
    textField: true,
    label: label,
    child: CupertinoTextField(
      key: key,
      controller: controller,
      focusNode: focus,
      placeholder: label,
      textInputAction: action,
      onSubmitted: onSubmitted,
      inputFormatters: [LengthLimitingTextInputFormatter(max)],
      padding: const EdgeInsets.all(14),
    ),
  );

  Widget _semanticButton({
    required Key key,
    required String label,
    required bool enabled,
    required VoidCallback onPressed,
    required Widget child,
    bool filled = false,
  }) => Semantics(
    button: true,
    enabled: enabled,
    label: label,
    onTap: enabled ? onPressed : null,
    excludeSemantics: true,
    child: CupertinoButton(
      key: key,
      minimumSize: const Size(double.infinity, 48),
      color: filled ? CupertinoColors.activeBlue : CupertinoColors.systemGrey5,
      onPressed: enabled ? onPressed : null,
      child: child,
    ),
  );
}

class _DocumentRow extends StatelessWidget {
  const _DocumentRow({required this.item, required this.copy});
  final HomeDocument item;
  final _Copy copy;
  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: '${item.title}, ${copy.privateDocument}',
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: CupertinoColors.separator.resolveFrom(context),
            width: .5,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(item.title, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              Text(copy.privateDocument),
              if (item.warranty.confirmedDate != null)
                Text('${copy.warranty}: ${item.warranty.confirmedDate}'),
              if (item.warranty.candidate != null &&
                  item.warranty.confirmedDate == null)
                Text(copy.ocrUnconfirmed),
            ],
          ),
        ],
      ),
    ),
  );
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
        context,
      ),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(
        color: CupertinoColors.separator.resolveFrom(context),
        width: .5,
      ),
    ),
    child: Padding(padding: const EdgeInsets.all(18), child: child),
  );
}

class _Notice extends StatelessWidget {
  const _Notice(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: CupertinoColors.systemOrange
          .resolveFrom(context)
          .withValues(alpha: .12),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(text),
  );
}

const _heading = TextStyle(fontSize: 20, fontWeight: FontWeight.w700);

class _Copy {
  const _Copy(this.tr);
  factory _Copy.of(BuildContext context) =>
      _Copy(Localizations.localeOf(context).languageCode == 'tr');
  final bool tr;
  String get title => tr ? 'Ev belgeleri' : 'Home documents';
  String get add => tr ? 'Belge ekle' : 'Add document';
  String get upload => tr ? 'Belge seç ve yükle' : 'Choose and upload';
  String get uploaded => tr ? 'Yüklendi' : 'Uploaded';
  String get ocrSuggestion =>
      tr ? 'OCR önerisi, henüz onaylı değil' : 'OCR suggestion, not confirmed';
  String get documentTitle => tr ? 'Belge başlığı' : 'Document title';
  String get documentKind => tr ? 'Belge türü' : 'Document type';
  String kind(HomeDocumentKind value) => switch (value) {
    HomeDocumentKind.invoice => tr ? 'Fatura' : 'Invoice',
    HomeDocumentKind.manual => tr ? 'Kılavuz' : 'Manual',
    HomeDocumentKind.warranty => tr ? 'Garanti' : 'Warranty',
    HomeDocumentKind.other => tr ? 'Diğer' : 'Other',
  };
  String get inventoryId => tr ? 'Envanter kimliği' : 'Inventory ID';
  String get resourceId =>
      tr ? 'Core belge kaynağı kimliği' : 'Core document resource ID';
  String get warrantyDate =>
      tr ? 'Garanti tarihi (YYYY-AA-GG)' : 'Warranty date (YYYY-MM-DD)';
  String get confirmWarranty => tr
      ? 'Garanti tarihini açıkça onayla'
      : 'Explicitly confirm warranty date';
  String get privateReaders =>
      tr ? 'Özel belge okuyucuları' : 'Private document readers';
  String get publish => tr ? 'Belgeyi kaydet' : 'Save document';
  String get library => tr ? 'Yetkili belgeler' : 'Authorized documents';
  String get refresh => tr ? 'Belgeleri yenile' : 'Refresh documents';
  String get empty => tr ? 'Görülebilir belge yok.' : 'No visible documents.';
  String get reminders => tr ? 'Garanti hatırlatmaları' : 'Warranty reminders';
  String get noReminders =>
      tr ? 'Onaylı hatırlatma yok.' : 'No confirmed reminders.';
  String get privateDocument => tr ? 'Özel belge' : 'Private document';
  String get warranty => tr ? 'Garanti' : 'Warranty';
  String get ocrUnconfirmed =>
      tr ? 'OCR tarihi onay bekliyor' : 'OCR date awaits confirmation';
  String get loading => tr ? 'Belgeler yükleniyor' : 'Loading documents';
  String get offline =>
      tr ? 'Larenor Core erişilemiyor.' : 'Larenor Core is offline.';
  String get stale => tr
      ? 'Hesap veya ekran değişti; özel veriler temizlendi.'
      : 'Account or screen changed; private data was cleared.';
  String get rejected =>
      tr ? 'Core işlemi reddetti.' : 'Core rejected the operation.';
  String get invalidResponse =>
      tr ? 'Core doğrulaması başarısız.' : 'Core verification failed.';
  String get invalidInput =>
      tr ? 'Belge alanlarını kontrol edin.' : 'Check the document fields.';
}
