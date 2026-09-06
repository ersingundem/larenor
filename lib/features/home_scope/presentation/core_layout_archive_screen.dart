import 'package:flutter/cupertino.dart';
import '../../settings/presentation/settings_file_dialog.dart';

class CoreLayoutArchiveScreen extends StatelessWidget {
  const CoreLayoutArchiveScreen({super.key, required this.gateCurrent, required this.runFileDialog});
  final bool Function() gateCurrent;
  final SettingsFileDialogRunner runFileDialog;
  @override Widget build(BuildContext context) => const SizedBox.shrink();
}
