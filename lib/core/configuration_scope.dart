import 'dart:ui' show ViewFocusEvent, ViewFocusState;
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/generated/app_localizations.dart';
import '../features/backup/data/backup_repository.dart';
import '../features/backup/data/backup_snapshot.dart';
import 'configuration_writes.dart';

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

  static Future<void> restorePrepared(
    BuildContext context, {
    required PreparedBackupRestore prepared,
    required String progressLabel,
    required String failureLabel,
    required String continueLabel,
  }) async {
    final state=context.findAncestorStateOfType<_ConfigurationScopeState>();
    if(state==null) throw StateError('ConfigurationScope is required for restore.');
    return state._restorePrepared(prepared,viewId:View.of(context).viewId,progressLabel:progressLabel,failureLabel:failureLabel,continueLabel:continueLabel);
  }

  @override
  State<ConfigurationScope> createState() => _ConfigurationScopeState();
}

class _ConfigurationScopeState extends State<ConfigurationScope> with WidgetsBindingObserver {
  var _generation = 0;
  var _restoring = false;
  var _failed = false;
  var _initializing = false;
  var _initializationFailed = false;
  String _progressLabel = '';
  String _failureLabel = '';
  String _continueLabel = '';
  int _boundaryEpoch=0;
  bool _handoffPending=false,_recovering=false,_focused=true;
  int? _restoreViewId;
  Object? _handoffOwner;
  Future<void> Function()? _pendingRecovery;
  bool get _active {
    final lifecycle=WidgetsBinding.instance.lifecycleState;
    return mounted && _focused && (lifecycle==null || lifecycle==AppLifecycleState.resumed);
  }
  @override void didChangeAppLifecycleState(AppLifecycleState state) {
    if(state!=AppLifecycleState.resumed) _boundaryEpoch++;
  }
  @override void didChangeViewFocus(ViewFocusEvent event) {
    if(_restoreViewId!=event.viewId) return;
    _focused=event.state==ViewFocusState.focused;
    if(!_focused) _boundaryEpoch++;
  }
  @override void dispose() {
    _boundaryEpoch++;
    _handoffOwner=null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
  Future<void> _restorePrepared(PreparedBackupRestore prepared,{
    required int viewId,required String progressLabel,required String failureLabel,required String continueLabel,
  }) async {
    if(_restoring || _handoffPending || !_active) throw const BackupException('restore_expired','Read the restore preview again.');
    _handoffPending=true;_restoreViewId=viewId;
    final epoch=_boundaryEpoch;
    try {
      await ConfigurationWrites.run(() async {
        if(!_active || epoch!=_boundaryEpoch) throw const BackupException('restore_expired','Read the restore preview again.');
        await prepared.checkBeforeHandoff();
        if(!_active || epoch!=_boundaryEpoch) throw const BackupException('restore_expired','Read the restore preview again.');
        final owner=Object();
        prepared.claimForHandoff(owner);
        _handoffOwner=owner;
        _pendingRecovery=prepared.recoverAfterHandoff;
        setState(() {
          _restoring=true;_failed=false;
          _progressLabel=progressLabel;_failureLabel=failureLabel;_continueLabel=continueLabel;
        });
        await WidgetsBinding.instance.endOfFrame;
        try {
          await prepared.applyAfterHandoff(owner,isCurrentBoundary:()=>_active && _restoring && epoch==_boundaryEpoch && identical(owner,_handoffOwner));
          if(mounted) {_pendingRecovery=null;_resume();}
        } catch(_) {
          if(mounted) setState(()=>_failed=true);
        } finally {_handoffOwner=null;}
      });
    } finally {_handoffPending=false;}
  }
  Future<void> _retryPreparedRecovery() async {
    if(_recovering || !_active) return;
    _recovering=true;setState(()=>_failed=false);
    try {
      await _pendingRecovery!();
      await widget.initialize?.call();
      if(mounted) {_pendingRecovery=null;_resume();}
    } catch(_) {if(mounted) setState(()=>_failed=true);}
    finally {_recovering=false;}
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
                          onPressed: _pendingRecovery!=null
                              ? _retryPreparedRecovery
                              : widget.initialize == null ? _resume : _initialize,
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
