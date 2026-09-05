import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qbittorrent_api/qbittorrent_api.dart';

import '../../../../l10n/generated/app_localizations.dart';

typedef TorrentModalPresenter = Future<T?> Function<T>(
  WidgetBuilder builder, {
  bool popup,
});
typedef TorrentIntentCapture = bool Function()? Function();

/// Ignore repeated callbacks once this modal has started closing.
void closeTorrentModal<T>(BuildContext context, [T? value]) {
  if (context.mounted && ModalRoute.of(context)?.isCurrent == true) {
    Navigator.pop(context, value);
  }
}

/// A validated local choice; the caller still checks its account immediately
/// before the one network dispatch. No URL or filename enters action receipts.
class TorrentAddIntent {
  const TorrentAddIntent(this.torrents, this.isCurrent);
  final NewTorrents torrents;
  final bool Function() isCurrent;
}

final torrentFileAccessProvider = Provider((ref) => TorrentFileAccess());

class TorrentFileAccess {
  static const maxBytes = 10 * 1024 * 1024;

  Future<FileBytes?> pick() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['torrent'],
    );
    if (file == null) return null;
    final name = file.name;
    if (name.length > 255 ||
        !name.toLowerCase().endsWith('.torrent') ||
        name.contains(RegExp(r'[/\\\x00-\x1f\x7f"]')) ||
        await file.length() > maxBytes) {
      throw const TorrentFileException();
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file.readAsByteStream()) {
      if (bytes.length + chunk.length > maxBytes) {
        throw const TorrentFileException();
      }
      bytes.add(chunk);
    }
    if (bytes.isEmpty) throw const TorrentFileException();
    return FileBytes(filename: name, bytes: bytes.takeBytes());
  }
}

class TorrentFileException implements Exception {
  const TorrentFileException();
}

/// A system picker may suspend the app. Its return only starts a fresh named
/// confirmation; it never inherits the pre-picker permission to send a request.
Future<TorrentAddIntent?> showAddTorrentSheet(
  BuildContext context, {
  required TorrentModalPresenter showModal,
  required TorrentIntentCapture captureIntent,
  required TorrentFileAccess fileAccess,
}) async {
  final original = captureIntent();
  if (original == null) return null;
  final choice = await showModal<String>(
    (context) => CupertinoActionSheet(
      title: Text(AppLocalizations.of(context).qbittorrentAddTorrentTitle),
      actions: [
        CupertinoActionSheetAction(
          key: const ValueKey('torrent-add-magnet'),
          onPressed: () => closeTorrentModal(context, 'magnet'),
          child: Text(AppLocalizations.of(context).qbittorrentPasteMagnetLink),
        ),
        CupertinoActionSheetAction(
          key: const ValueKey('torrent-add-file'),
          onPressed: () => closeTorrentModal(context, 'file'),
          child: Text(AppLocalizations.of(context).qbittorrentChooseFile),
        ),
      ],
      cancelButton: CupertinoActionSheetAction(
        onPressed: () => closeTorrentModal(context),
        child: Text(AppLocalizations.of(context).commonCancel),
      ),
    ),
    popup: true,
  );
  if (!context.mounted || !original()) return null;
  if (choice == 'magnet') {
    final magnet = await showModal<String>((context) => const _MagnetDialog());
    if (!context.mounted || !original() || magnet == null) return null;
    return TorrentAddIntent(NewTorrents.urls(urls: [magnet]), original);
  }
  if (choice != 'file') return null;
  final file = await fileAccess.pick();
  if (!context.mounted || file == null) return null;
  // captureIntent checks the originally selected account/client and foreground,
  // but intentionally captures a NEW lifecycle generation after the OS picker.
  final fresh = captureIntent();
  if (fresh == null) return null;
  final confirmed = await showModal<bool>(
    (context) => CupertinoAlertDialog(
      title: Text(AppLocalizations.of(context).qbittorrentAddTorrentTitle),
      content: Text(
        AppLocalizations.of(context).qbittorrentFileConfirmation(file.filename),
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => closeTorrentModal(context, false),
          child: Text(AppLocalizations.of(context).commonCancel),
        ),
        CupertinoDialogAction(
          key: const ValueKey('torrent-confirm-file'),
          onPressed: () => closeTorrentModal(context, true),
          child: Text(AppLocalizations.of(context).commonAdd),
        ),
      ],
    ),
  );
  if (!context.mounted || !fresh() || confirmed != true) return null;
  return TorrentAddIntent(NewTorrents.bytes(bytes: [file]), fresh);
}

class _MagnetDialog extends StatefulWidget {
  const _MagnetDialog();
  @override
  State<_MagnetDialog> createState() => _MagnetDialogState();
}

class _MagnetDialogState extends State<_MagnetDialog> {
  final _controller = TextEditingController();
  bool _invalid = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _confirm() {
    if (!mounted) return;
    final value = _controller.text.trim();
    final uri = Uri.tryParse(value);
    if (value.isEmpty ||
        value.length > 8192 ||
        value.contains(RegExp(r'[\s\x00-\x1f\x7f]')) ||
        uri?.scheme != 'magnet' ||
        !(uri!.queryParametersAll['xt'] ?? []).any(
          (xt) => xt.startsWith('urn:btih:') || xt.startsWith('urn:btmh:'),
        )) {
      setState(() => _invalid = true);
      return;
    }
    closeTorrentModal(context, value);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return CupertinoAlertDialog(
      title: Text(l10n.qbittorrentMagnetLinkTitle),
      content: Column(
        children: [
          const SizedBox(height: 12),
          CupertinoTextField(
            key: const ValueKey('torrent-magnet-field'),
            controller: _controller,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            maxLength: 8192,
            placeholder: 'magnet:?xt=urn:btih:…',
          ),
          if (_invalid) Text(l10n.qbittorrentInvalidMagnet),
        ],
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => closeTorrentModal(context),
          child: Text(l10n.commonCancel),
        ),
        CupertinoDialogAction(
          key: const ValueKey('torrent-confirm-magnet'),
          onPressed: _confirm,
          child: Text(l10n.commonAdd),
        ),
      ],
    );
  }
}
