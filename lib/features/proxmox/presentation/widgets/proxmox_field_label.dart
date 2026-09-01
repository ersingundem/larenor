import '../../../../l10n/generated/app_localizations.dart';

/// Config keys that should never be shown/edited at all — internal
/// bookkeeping fields, not real guest settings. `digest` in particular is
/// a hash of the config used for optimistic-concurrency checks; showing
/// or round-tripping it as an editable text field is meaningless.
const proxmoxHiddenConfigKeys = {'digest'};

final RegExp _numberedKey = RegExp(r'^([a-zA-Z]+?)(\d+)$');

/// Turns a raw Proxmox `/config` key (e.g. `net0`, `ostype`, `scsi0`) into
/// a human-readable label instead of showing the API field name verbatim.
/// Covers every commonly-seen key across QEMU VMs and LXC containers;
/// anything genuinely unrecognized still gets a best-effort "Title Case"
/// prettification rather than the raw snake/lower-case key.
String proxmoxFieldLabel(AppLocalizations l10n, String key) {
  switch (key) {
    case 'name':
      return l10n.proxmoxFieldName;
    case 'hostname':
      return l10n.proxmoxFieldHostname;
    case 'cores':
      return l10n.proxmoxFieldCores;
    case 'memory':
      return l10n.proxmoxFieldMemory;
    case 'onboot':
      return l10n.proxmoxFieldOnboot;
    case 'boot':
      return l10n.proxmoxFieldBoot;
    case 'bootdisk':
      return l10n.proxmoxFieldBootdisk;
    case 'ostype':
      return l10n.proxmoxFieldOstype;
    case 'agent':
      return l10n.proxmoxFieldAgent;
    case 'numa':
      return l10n.proxmoxFieldNuma;
    case 'sockets':
      return l10n.proxmoxFieldSockets;
    case 'arch':
      return l10n.proxmoxFieldArch;
    case 'swap':
      return l10n.proxmoxFieldSwap;
    case 'unprivileged':
      return l10n.proxmoxFieldUnprivileged;
    case 'features':
      return l10n.proxmoxFieldFeatures;
    case 'tags':
      return l10n.proxmoxFieldTags;
    case 'description':
      return l10n.proxmoxFieldDescription;
    case 'vmgenid':
      return l10n.proxmoxFieldVmgenid;
    case 'smbios1':
      return l10n.proxmoxFieldSmbios1;
    case 'tablet':
      return l10n.proxmoxFieldTablet;
    case 'startup':
      return l10n.proxmoxFieldStartup;
    case 'cpu':
      return l10n.proxmoxFieldCpu;
    case 'cpulimit':
      return l10n.proxmoxFieldCpulimit;
    case 'cpuunits':
      return l10n.proxmoxFieldCpuunits;
    case 'vcpus':
      return l10n.proxmoxFieldVcpus;
    case 'hotplug':
      return l10n.proxmoxFieldHotplug;
    case 'protection':
      return l10n.proxmoxFieldProtection;
    case 'template':
      return l10n.proxmoxFieldTemplate;
    case 'rootfs':
      return l10n.proxmoxFieldRootfs;
    case 'searchdomain':
      return l10n.proxmoxFieldSearchdomain;
    case 'nameserver':
      return l10n.proxmoxFieldNameserver;
    case 'ostemplate':
      return l10n.proxmoxFieldOstemplate;
    case 'vga':
      return l10n.proxmoxFieldVga;
    case 'machine':
      return l10n.proxmoxFieldMachine;
    case 'balloon':
      return l10n.proxmoxFieldBalloon;
  }

  final numbered = _numberedKey.firstMatch(key);
  if (numbered != null) {
    final prefix = numbered.group(1)!;
    final index = int.parse(numbered.group(2)!);
    switch (prefix) {
      case 'net':
        return l10n.proxmoxFieldNetworkInterface(index);
      case 'scsi':
      case 'sata':
      case 'virtio':
      case 'ide':
        return l10n.proxmoxFieldStorageDevice(prefix.toUpperCase(), index);
      case 'mp':
        return l10n.proxmoxFieldMountPoint(index);
      case 'unused':
        return l10n.proxmoxFieldUnusedDisk(index);
      case 'ipconfig':
        return l10n.proxmoxFieldIpConfig(index);
    }
  }

  return _prettify(key);
}

String _prettify(String key) {
  final withSpaces = key.replaceAll(RegExp(r'[_-]'), ' ');
  return withSpaces
      .split(' ')
      .where((w) => w.isNotEmpty)
      .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');
}
