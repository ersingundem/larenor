import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/generated/app_localizations.dart';

/// Owns the lifetime of every configuration-dependent provider and route.
/// Restoring credentials disposes the old session before persistence begins;
/// the next session reads configuration from storage with no cached clients.
class ConfigurationScope extends StatefulWidget {
  const ConfigurationScope({super.key, required this.child, this.initialize});

  final Widget child;
  final Future<void> Function()? initialize;

  static Future<void> restore(
    BuildContext context, {
    required Future<void> Function() operation,
    required String progressLabel,
    required String failureLabel,
    required String continueLabel,
  }) {
    final state = context.findAncestorStateOfType<_ConfigurationScopeState>();
    if (state == null) {
      throw StateError('ConfigurationScope is required for restore.');
    }
    return state._restore(
      operation,
      progressLabel: progressLabel,
      failureLabel: failureLabel,
      continueLabel: continueLabel,
    );
  }

  @override
  State<ConfigurationScope> createState() => _ConfigurationScopeState();
}

class _ConfigurationScopeState extends State<ConfigurationScope> {
  var _generation = 0;
  var _restoring = false;
  var _failed = false;
  var _initializing = false;
  var _initializationFailed = false;
  String _progressLabel = '';
  String _failureLabel = '';
  String _continueLabel = '';

  @override
  void initState() {
    super.initState();
    if (widget.initialize != null) _initialize();
  }

  Future<void> _initialize() async {
    setState(() {
      _initializing = true;
      _initializationFailed = false;
    });
    try {
      await widget.initialize?.call();
      if (mounted) {
        setState(() {
          _initializing = false;
          _restoring = false;
          _failed = false;
          _generation++;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _initializationFailed = true);
    }
  }

  Future<void> _restore(
    Future<void> Function() operation, {
    required String progressLabel,
    required String failureLabel,
    required String continueLabel,
  }) async {
    if (_restoring) return;
    setState(() {
      _restoring = true;
      _failed = false;
      _progressLabel = progressLabel;
      _failureLabel = failureLabel;
      _continueLabel = continueLabel;
    });
    // Wait for unmount/dispose, not merely the setState call. No old route or
    // provider can start another configuration change while storage is written.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    try {
      await operation();
    } catch (_) {
      // Storage errors may contain credential values. Never render/log them.
      if (mounted) setState(() => _failed = true);
      return;
    }
    if (mounted) _resume();
  }

  void _resume() => setState(() {
    _generation++;
    _restoring = false;
    _failed = false;
  });

  @override
  Widget build(BuildContext context) {
    if (_initializing) {
      return CupertinoApp(
        debugShowCheckedModeBanner: false,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            final l10n = AppLocalizations.of(context);
            return CupertinoPageScaffold(
              child: SafeArea(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!_initializationFailed)
                          const CupertinoActivityIndicator(),
                        const SizedBox(height: 16),
                        Text(
                          _initializationFailed
                              ? l10n.backupRecoveryFailed
                              : l10n.backupRecoveryProgress,
                          textAlign: TextAlign.center,
                        ),
                        if (_initializationFailed)
                          CupertinoButton.filled(
                            onPressed: _initialize,
                            child: Text(l10n.commonRetry),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );
    }
    if (!_restoring) {
      return ProviderScope(key: ValueKey(_generation), child: widget.child);
    }
    return CupertinoApp(
      debugShowCheckedModeBanner: false,
      home: PopScope(
        canPop: false,
        child: CupertinoPageScaffold(
          child: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!_failed) const CupertinoActivityIndicator(),
                      const SizedBox(height: 16),
                      Text(
                        _failed ? _failureLabel : _progressLabel,
                        textAlign: TextAlign.center,
                      ),
                      if (_failed) ...[
                        const SizedBox(height: 16),
                        CupertinoButton.filled(
                          onPressed: widget.initialize == null
                              ? _resume
                              : _initialize,
                          child: Text(_continueLabel),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
