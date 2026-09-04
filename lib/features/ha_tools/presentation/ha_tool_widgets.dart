import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/typography.dart';

class HaHint extends StatelessWidget {
  const HaHint(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Text(
      text,
      style: AppText.footnote.copyWith(
        color: CupertinoColors.secondaryLabel.resolveFrom(context),
      ),
    ),
  );
}

class HaTextInput extends StatelessWidget {
  const HaTextInput({
    super.key,
    required this.label,
    required this.controller,
    this.lines = 1,
    this.readOnly = false,
  });
  final String label;
  final TextEditingController controller;
  final int lines;
  final bool readOnly;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppText.footnote),
        const SizedBox(height: 8),
        Semantics(
          label: label,
          child: CupertinoTextField(
            controller: controller,
            minLines: lines,
            maxLines: lines + 5,
            readOnly: readOnly,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: lines > 1
                ? TextInputType.multiline
                : TextInputType.text,
            padding: const EdgeInsets.all(12),
          ),
        ),
      ],
    ),
  );
}

class HaResult extends StatelessWidget {
  const HaResult({super.key, required this.value, this.isError = false});
  final Object? value;
  final bool isError;
  @override
  Widget build(BuildContext context) {
    final text = value is String
        ? value as String
        : const JsonEncoder.withIndent('  ').convert(value);
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isError
                ? AppLocalizations.of(context).commonError
                : AppLocalizations.of(context).haResult,
            style: AppText.headline.copyWith(
              color: isError
                  ? CupertinoColors.systemRed.resolveFrom(context)
                  : null,
            ),
          ),
          const SizedBox(height: 12),
          SelectableText(
            text,
            style: AppText.footnote.copyWith(fontFamily: 'monospace'),
          ),
        ],
      ),
    );
  }
}

Future<bool> confirmHaAction(BuildContext context, String request) async {
  final l10n = AppLocalizations.of(context);
  return await showCupertinoDialog<bool>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: Text(l10n.haConfirmRun),
          content: Text(request),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.commonCancel),
            ),
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.haRun),
            ),
          ],
        ),
      ) ??
      false;
}
