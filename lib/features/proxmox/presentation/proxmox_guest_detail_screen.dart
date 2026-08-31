import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/proxmox_guest.dart';
import '../providers/proxmox_providers.dart';
import 'console/proxmox_console_screen.dart';
import 'widgets/proxmox_usage_bar.dart';

/// Config keys treated as "common" and given friendly labels; everything
/// else in the guest's config is still shown and editable, just under an
/// "Advanced" section with its raw key as the label.
const _nameKeysByType = {
  ProxmoxGuestType.qemu: 'name',
  ProxmoxGuestType.lxc: 'hostname',
};
const _commonKeys = ['cores', 'memory', 'onboot'];

class ProxmoxGuestDetailScreen extends ConsumerStatefulWidget {
  const ProxmoxGuestDetailScreen({super.key, required this.guest});

  final ProxmoxGuest guest;

  @override
  ConsumerState<ProxmoxGuestDetailScreen> createState() =>
      _ProxmoxGuestDetailScreenState();
}

class _ProxmoxGuestDetailScreenState
    extends ConsumerState<ProxmoxGuestDetailScreen> {
  final Map<String, TextEditingController> _controllers = {};
  bool _onboot = false;
  bool _saving = false;
  String? _error;
  Map<String, dynamic>? _loadedConfig;

  String get _nameKey => _nameKeysByType[widget.guest.type]!;

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _seedControllers(Map<String, dynamic> config) {
    if (_loadedConfig != null) return;
    _loadedConfig = config;
    for (final entry in config.entries) {
      if (entry.key == 'onboot') {
        _onboot = '${entry.value}' == '1';
        continue;
      }
      _controllers[entry.key] = TextEditingController(text: '${entry.value}');
    }
  }

  Future<void> _save() async {
    final client = ref.read(proxmoxClientProvider).value;
    if (client == null) return;

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final changes = <String, String>{
        for (final entry in _controllers.entries) entry.key: entry.value.text,
        'onboot': _onboot ? '1' : '0',
      };
      await client.updateGuestConfig(
        widget.guest.node,
        widget.guest.type,
        widget.guest.vmid,
        changes,
      );
      ref.invalidate(
        proxmoxGuestConfigProvider(
          widget.guest.node,
          widget.guest.type,
          widget.guest.vmid,
        ),
      );
      ref.invalidate(proxmoxGuestsProvider(widget.guest.node));
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = 'Could not save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openConsole() async {
    await Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => ProxmoxConsoleScreen(guest: widget.guest),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final guest = widget.guest;
    final configAsync = ref.watch(
      proxmoxGuestConfigProvider(guest.node, guest.type, guest.vmid),
    );

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(guest.name)),
      child: SafeArea(
        child: configAsync.when(
          loading: () => const Center(child: CupertinoActivityIndicator()),
          error: (error, _) => Center(child: Text('Failed to load: $error')),
          data: (config) {
            _seedControllers(config);
            final commonKeys = [
              _nameKey,
              ..._commonKeys,
            ].where(config.containsKey);
            final advancedKeys = config.keys.where(
              (k) => !commonKeys.contains(k) && k != 'onboot',
            );

            return ListView(
              children: [
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: ProxmoxUsageBar(
                          label: 'CPU',
                          fraction: guest.cpuFraction,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ProxmoxUsageBar(
                          label: 'RAM',
                          fraction: guest.memFraction,
                        ),
                      ),
                    ],
                  ),
                ),
                CupertinoListSection.insetGrouped(
                  header: const Text('DETAILS'),
                  children: [
                    for (final key in commonKeys)
                      CupertinoTextFormFieldRow(
                        controller: _controllers[key],
                        prefix: Text(_friendlyLabel(key)),
                      ),
                    CupertinoListTile(
                      title: const Text('Start on boot'),
                      trailing: CupertinoSwitch(
                        value: _onboot,
                        onChanged: (value) => setState(() => _onboot = value),
                      ),
                    ),
                  ],
                ),
                if (advancedKeys.isNotEmpty)
                  CupertinoListSection.insetGrouped(
                    header: const Text('ADVANCED'),
                    footer: const Text(
                      'Raw config values — edit with care, invalid values '
                      'can prevent this guest from starting.',
                    ),
                    children: [
                      for (final key in advancedKeys)
                        CupertinoTextFormFieldRow(
                          controller: _controllers[key],
                          prefix: Text(key),
                        ),
                    ],
                  ),
                CupertinoListSection.insetGrouped(
                  header: const Text('CONSOLE'),
                  children: [
                    CupertinoListTile(
                      leading: const Icon(CupertinoIcons.desktopcomputer),
                      title: const Text('Open console'),
                      trailing: const CupertinoListTileChevron(),
                      onTap: _openConsole,
                    ),
                  ],
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: CupertinoColors.systemRed.resolveFrom(context),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: CupertinoButton.filled(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const CupertinoActivityIndicator(
                            color: CupertinoColors.white,
                          )
                        : const Text('Save'),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  String _friendlyLabel(String key) => switch (key) {
    'name' => 'Name',
    'hostname' => 'Hostname',
    'cores' => 'CPU cores',
    'memory' => 'Memory (MB)',
    _ => key,
  };
}
