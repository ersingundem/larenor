import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/spacing.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';

const larenorSourceUrl = 'https://github.com/ersingundem/larenor';
const _bundled = <(String, String)>[
  ('Larenor — GNU AGPL v3', 'LICENSE'),
  ('Larenor — NOTICE', 'NOTICE'),
  ('Third-party notices', 'THIRD_PARTY_NOTICES.md'),
  ('Inter — SIL OFL 1.1', 'assets/fonts/OFL.txt'),
  ('noVNC — MPL 2.0', 'assets/console/novnc/docs/LICENSE.MPL-2.0'),
  ('noVNC — notices', 'assets/console/novnc/LICENSE.txt'),
  ('pako — MIT', 'assets/console/novnc/vendor/pako/LICENSE'),
  ('xterm.js — MIT', 'assets/console/xterm/LICENSE'),
  ('Android apksig — Apache 2.0', 'assets/licenses/apksig-APACHE-2.0.txt'),
];

/// Local license documents and registered package notices. Opening this screen
/// never contacts a repository or transmits configured service information.
class LegalScreen extends StatefulWidget {
  const LegalScreen({super.key});
  @override
  State<LegalScreen> createState() => _LegalScreenState();
}

class _LegalScreenState extends State<LegalScreen> {
  late final Future<List<LicenseEntry>> _packages = LicenseRegistry.licenses
      .toList();
  bool _copied = false;
  bool _foreground = true, _ticker = true;
  int _generation = 0;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        final foreground = state == AppLifecycleState.resumed;
        if (!mounted || foreground == _foreground) return;
        setState(() {
          if (_foreground && !foreground) _generation++;
          _foreground = foreground;
        });
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ticker = TickerMode.valuesOf(context).enabled;
    if (_ticker && !ticker) _generation++;
    _ticker = ticker;
  }

  bool _current(int generation) =>
      mounted &&
      generation == _generation &&
      _foreground &&
      _ticker &&
      ModalRoute.of(context)?.isCurrent != false;

  void _open(int generation, String title, Future<String> Function() load) {
    if (!_current(generation)) return;
    Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => _LicenseDocument(title: title, load: load),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final generation = _generation;
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(l10n.legalTitle)),
      child: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 780),
            child: ListView(
              children: [
                SettingsSection(
                  header: Semantics(
                    container: true,
                    header: true,
                    child: Text(l10n.legalSource),
                  ),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(Gap.xl),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(l10n.legalLicenseSummary),
                          Gap.vMd,
                          const Text(
                            'Copyright © 2026 Ersin Gündem and Larenor contributors',
                          ),
                          Gap.vLg,
                          const Text(larenorSourceUrl),
                          CupertinoButton(
                            key: const ValueKey('legal-copy-source'),
                            minimumSize: const Size(48, 48),
                            alignment: AlignmentDirectional.centerStart,
                            padding: EdgeInsets.zero,
                            onPressed: () async {
                              if (!_current(generation)) return;
                              await Clipboard.setData(
                                const ClipboardData(text: larenorSourceUrl),
                              );
                              if (_current(generation)) {
                                setState(() => _copied = true);
                              }
                            },
                            child: Text(
                              _copied ? l10n.legalCopied : l10n.legalCopySource,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                SettingsSection(
                  children: [
                    for (final (title, asset) in _bundled)
                      _row(
                        title,
                        () => _open(
                          generation,
                          title,
                          () => rootBundle.loadString(asset),
                        ),
                        buttonKey: ValueKey('legal-document-$asset'),
                      ),
                  ],
                ),
                FutureBuilder<List<LicenseEntry>>(
                  future: _packages,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return Padding(
                        padding: const EdgeInsets.all(Gap.xl),
                        child: Text(l10n.legalLoadError),
                      );
                    }
                    if (!snapshot.hasData) {
                      return const Center(child: CupertinoActivityIndicator());
                    }
                    if (snapshot.data!.isEmpty) return const SizedBox.shrink();
                    return SettingsSection(
                      header: Semantics(
                        container: true,
                        header: true,
                        child: Text(l10n.legalThirdParty),
                      ),
                      children: [
                        for (final entry in snapshot.data!)
                          _row(
                            entry.packages.join(', '),
                            () => _open(
                              generation,
                              entry.packages.join(', '),
                              () async => entry.paragraphs
                                  .map((p) => p.text)
                                  .join('\n\n'),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(String title, VoidCallback onTap, {Key? buttonKey}) =>
      SettingsActionTile(
        buttonKey: buttonKey,
        title: Text(title),
        onTap: onTap,
      );

  @override
  void dispose() {
    _generation++;
    _lifecycle.dispose();
    super.dispose();
  }
}

class _LicenseDocument extends StatefulWidget {
  const _LicenseDocument({required this.title, required this.load});
  final String title;
  final Future<String> Function() load;
  @override
  State<_LicenseDocument> createState() => _LicenseDocumentState();
}

class _LicenseDocumentState extends State<_LicenseDocument> {
  late final Future<String> _text = widget.load();
  @override
  Widget build(BuildContext context) => AppPageScaffold(
    navigationBar: CupertinoNavigationBar(
      middle: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
    child: SafeArea(
      child: FutureBuilder<String>(
        future: _text,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Text(AppLocalizations.of(context).legalLoadError),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CupertinoActivityIndicator());
          }
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 780),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(Gap.xxl),
                child: Text(
                  snapshot.data!,
                  style: const TextStyle(fontSize: 14, height: 1.5),
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
}
