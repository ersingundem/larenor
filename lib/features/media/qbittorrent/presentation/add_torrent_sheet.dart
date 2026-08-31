import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:qbittorrent_api/qbittorrent_api.dart';

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
      title: const Text('Add Torrent'),
      actions: [
        CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context, 'magnet'),
          child: const Text('Paste Magnet Link'),
        ),
        CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context, 'file'),
          child: const Text('Choose .torrent File'),
        ),
      ],
      cancelButton: CupertinoActionSheetAction(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
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
      title: const Text('Magnet Link'),
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
          child: const Text('Cancel'),
        ),
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          child: const Text('Add'),
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
