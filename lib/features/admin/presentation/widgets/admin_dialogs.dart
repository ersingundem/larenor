import 'package:flutter/cupertino.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../data/models/ha_area.dart';

Future<void> showAdminMessage(
  BuildContext context,
  String message, {
  bool error = true,
}) => showCupertinoDialog<void>(
  context: context,
  builder: (context) => CupertinoAlertDialog(
    title: Text(
      error
          ? AppLocalizations.of(context).commonError
          : AppLocalizations.of(context).commonDone,
    ),
    content: Text(message),
    actions: [
      CupertinoDialogAction(
        onPressed: () => Navigator.pop(context),
        child: Text(AppLocalizations.of(context).commonOk),
      ),
    ],
  ),
);

Future<String?> promptAdminName(
  BuildContext context, {
  required String title,
  String initial = '',
}) async {
  final controller = TextEditingController(text: initial);
  final value = await showCupertinoDialog<String>(
    context: context,
    builder: (context) => CupertinoAlertDialog(
      title: Text(title),
      content: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: CupertinoTextField(controller: controller, autofocus: true),
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(context),
          child: Text(AppLocalizations.of(context).commonCancel),
        ),
        CupertinoDialogAction(
          onPressed: () {
            if (controller.text.trim().isNotEmpty) {
              Navigator.pop(context, controller.text.trim());
            }
          },
          child: Text(AppLocalizations.of(context).commonSave),
        ),
      ],
    ),
  );
  // The route may still animate while its text field uses this controller.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  controller.dispose();
  return value;
}

Future<String?> pickAdminArea(
  BuildContext context,
  List<HaArea> areas,
  String? selected,
) => showCupertinoModalPopup<String>(
  context: context,
  builder: (context) => CupertinoActionSheet(
    title: Text(AppLocalizations.of(context).adminArea),
    actions: [
      CupertinoActionSheetAction(
        isDefaultAction: selected == null,
        onPressed: () => Navigator.pop(context, ''),
        child: Text(AppLocalizations.of(context).commonNone),
      ),
      for (final area in areas)
        CupertinoActionSheetAction(
          isDefaultAction: selected == area.areaId,
          onPressed: () => Navigator.pop(context, area.areaId),
          child: Text(area.name),
        ),
    ],
    cancelButton: CupertinoActionSheetAction(
      onPressed: () => Navigator.pop(context),
      child: Text(AppLocalizations.of(context).commonCancel),
    ),
  ),
);
