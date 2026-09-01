import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:qbittorrent_api/qbittorrent_api.dart';

import '../../../../l10n/generated/app_localizations.dart';

/// Add-torrent entry point: magnet link (pasted into a text field) or a
/// `.torrent` file picked from the device via the platform file chooser.
Future<void> showAddTorrentSheet(
  BuildContext context,
  QBittorrentApiV2 client,
  VoidCallback onAdded,
) async {
  final choice = await showCupertinoModalPopup<String>(
    context: context,
    builder: (context) => CupertinoActionSheet(
      title: Text(AppLocalizations.of(context).qbittorrentAddTorrentTitle),
      actions: [
        CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context, 'magnet'),
          child: Text(AppLocalizations.of(context).qbittorrentPasteMagnetLink),
        ),
        CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context, 'file'),
          child: Text(AppLocalizations.of(context).qbittorrentChooseFile),
        ),
      ],
      cancelButton: CupertinoActionSheetAction(
        onPressed: () => Navigator.pop(context),
        child: Text(AppLocalizations.of(context).commonCancel),
      ),
    ),
  );

  if (!context.mounted) return;
  if (choice == 'magnet') {
    await _addByMagnet(context, client, onAdded);
  } else if (choice == 'file') {
    await _addByFile(client, onAdded);
  }
}

Future<void> _addByMagnet(
  BuildContext context,
  QBittorrentApiV2 client,
  VoidCallback onAdded,
) async {
  final controller = TextEditingController();
  final magnet = await showCupertinoDialog<String>(
    context: context,
    builder: (context) => CupertinoAlertDialog(
      title: Text(AppLocalizations.of(context).qbittorrentMagnetLinkTitle),
      content: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: CupertinoTextField(
          controller: controller,
          autofocus: true,
          placeholder: 'magnet:?xt=urn:btih:...',
        ),
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(context),
          child: Text(AppLocalizations.of(context).commonCancel),
        ),
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          child: Text(AppLocalizations.of(context).commonAdd),
        ),
      ],
    ),
  );

  if (magnet == null || magnet.isEmpty) return;
  await client.torrents.addNewTorrents(
    torrents: NewTorrents.urls(urls: [magnet]),
  );
  onAdded();
}

Future<void> _addByFile(QBittorrentApiV2 client, VoidCallback onAdded) async {
  final file = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: ['torrent'],
  );
  final path = file?.path;
  if (path == null) return;

  await client.torrents.addNewTorrents(
    torrents: NewTorrents.files(files: [File(path)]),
  );
  onAdded();
}
