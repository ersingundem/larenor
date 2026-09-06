import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/cupertino.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../core/home_session_controller.dart';
import '../../../core/window/window_policy_providers.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../dashboard/data/dashboard_repository.dart';
import '../../dashboard/providers/dashboard_providers.dart';
import '../../server/domain/server_models.dart';
import '../../settings/presentation/settings_file_dialog.dart';
import '../../settings/providers/settings_providers.dart';
import '../data/core_layout_archive_codec.dart';
import '../data/core_layout_archive_controller.dart';
import '../data/home_layout_access.dart';
import '../domain/core_layout_archive.dart';
import 'core_layout_archive_file_access.dart';

final coreLayoutArchiveCodecProvider = Provider<CoreLayoutArchiveCodec>(
  (_) => const CoreLayoutArchiveCodec(),
);

/// Local, same-Core/home/user room archive. The file dialog carries ciphertext
/// only; returning from it never revives an old controller or confirmation.
class CoreLayoutArchiveScreen extends ConsumerStatefulWidget {
  const CoreLayoutArchiveScreen({super.key, required this.gateCurrent, required this.runFileDialog});
  final bool Function() gateCurrent;
  final SettingsFileDialogRunner runFileDialog;
  @override ConsumerState<CoreLayoutArchiveScreen> createState() => _CoreLayoutArchiveScreenState();
}

class _CoreLayoutArchiveScreenState extends ConsumerState<CoreLayoutArchiveScreen> with WidgetsBindingObserver {
  final _scroll=ScrollController();
  final _password=TextEditingController(), _repeat=TextEditingController(), _openPassword=TextEditingController();
  late final HomeSessionController? _home;
  late final ServerSession? _session;
  late final int? _accountGeneration;
  late final DateTime Function() _clock;
  late final DateTime _openedAt;
  ProviderContainer? _container;
  DashboardRepository? _repository;
  HomeLayoutAccess? _access;
  CoreLayoutArchiveController? _controller;
  CoreLayoutArchivePreview? _preview;
  Uint8List? _file;
  List<String>? _rooms;
  AppInteractionController? _interaction;
  int _interactionEpoch=0, _generation=0, _binding=0;
  int? _viewId;
  bool _pinResolved=false, _foreground=true, _focused=true, _closed=false, _busy=false, _fileDialog=false, _started=false;
  String? _pin, _message;
  bool _error=false, _scheduled=false;
  Route<bool>? _dialog;
  Timer? _timer;

  @override void initState(){
    super.initState();
    _home=ref.read(homeSessionControllerProvider);
    _session=_home?.account.session; _accountGeneration=_home?.account.generation;
    _clock=ref.read(homeLayoutClockProvider); _openedAt=_clock();
    _home?.addListener(_homeChanged);
    final state=WidgetsBinding.instance.lifecycleState;
    _foreground=state==null || state==AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _timer=Timer(CoreLayoutArchiveController.lifetime,()=>_retire());
  }

  bool _sameOwner(){
    final elapsed=_clock().difference(_openedAt);
    return mounted && !_closed && _home!=null &&
      identical(ProviderScope.containerOf(context,listen:false),_container) &&
      identical(ref.read(homeSessionControllerProvider),_home) &&
      identical(_home!.account.session,_session) && _home!.account.generation==_accountGeneration &&
      elapsed>=Duration.zero && elapsed<CoreLayoutArchiveController.lifetime;
  }
  bool _windowCurrent(){
    final window=ref.read(windowPolicySnapshotProvider);
    if(window.isLoading || window.hasError || !window.hasValue)return false;
    final w=window.requireValue;
    return !w.supported || w.isResumed && w.hasWindowFocus && !w.isPictureInPicture;
  }
  bool _baseCurrent(){
    if(!_sameOwner() || !_foreground || !_focused || !widget.gateCurrent() ||
      (_interaction?.active==false) || !TickerMode.valuesOf(context).enabled) return false;
    final pin=ref.read(pinLockProvider);
    if(!_pinResolved || pin.isLoading || pin.hasError || !pin.hasValue || pin.value!=_pin ||
       !_windowCurrent()) return false;
    return ModalRoute.of(context)?.isCurrent==true || _dialog?.isCurrent==true;
  }
  bool _current() => _baseCurrent() && _access?.isCurrent==true &&
    identical(ref.read(dashboardRepositoryProvider),_repository);
  bool _allowed(int generation){
    if(generation==_generation && _current()) return true;
    if(mounted && !_current()) _retire();
    return false;
  }
  void _changed(){
    if(!mounted || _scheduled) return;
    if(SchedulerBinding.instance.schedulerPhase==SchedulerPhase.persistentCallbacks){
      _scheduled=true; WidgetsBinding.instance.addPostFrameCallback((_){_scheduled=false;if(mounted)setState((){});});
    } else {setState((){});}
  }
  void _discard(){
    _binding++; _controller?.close(); _controller=null; _access=null; _repository=null; _preview=null;
    _password.clear();_repeat.clear();_openPassword.clear();_file=null;_rooms=null;
    final route=_dialog;_dialog=null;
    if(route?.isActive==true){
      void remove(){if(route?.isActive==true)route!.navigator?.removeRoute(route);}
      if(SchedulerBinding.instance.schedulerPhase==SchedulerPhase.persistentCallbacks){WidgetsBinding.instance.addPostFrameCallback((_)=>remove());}else{remove();}
    }
  }
  void _retire({bool permanent=true}){
    _generation++;_discard();_message=null;
    if(permanent)_closed=true;
    if(!_fileDialog)_busy=false;
    _changed();
  }
  void _homeChanged()=>_retire();
  void _interactionChanged(){
    final epoch=_interaction?.epoch??0;
    if(epoch!=_interactionEpoch){_interactionEpoch=epoch;_retire(permanent:!_fileDialog);}else{_changed();}
  }
  @override void didChangeDependencies(){
    super.didChangeDependencies();
    final viewId=View.of(context).viewId;
    if(_viewId!=null && _viewId!=viewId)_retire();
    _viewId=viewId;
    final container=ProviderScope.containerOf(context);
    if(_container==null){_container=container;}else if(!identical(container,_container)){_retire();}
    final next=AppInteractionScope.maybeOf(context);
    if(!identical(next,_interaction)){
      final old=_interaction;old?.removeListener(_interactionChanged);_interaction=next;_interactionEpoch=next?.epoch??0;next?.addListener(_interactionChanged);
      if(old!=null)_retire();
    }
    if(_started && !TickerMode.valuesOf(context).enabled)_retire(permanent:!_fileDialog);
  }
  @override void didChangeAppLifecycleState(AppLifecycleState state){
    _foreground=state==AppLifecycleState.resumed;
    if(!_foreground)_retire(permanent:!_fileDialog);else _changed();
  }
  @override void didChangeViewFocus(ViewFocusEvent event){
    if(event.viewId!=_viewId)return;
    _focused=event.state==ViewFocusState.focused;
    if(!_focused)_retire(permanent:!_fileDialog);else _changed();
  }

  bool _bind(){
    if(!_baseCurrent())return false;
    final access=homeLayoutAccess(_home,clock:_clock), repository=ref.read(dashboardRepositoryProvider);
    if(access==null || repository.scope!=access.scope)return false;
    _controller?.close();_binding++;
    final binding=_binding;
    _access=access;_repository=repository;
    _controller=CoreLayoutArchiveController(destination:repository,clock:_clock,isCurrent:()=>binding==_binding && _current());
    return true;
  }
  Future<bool> _durablePin(int generation) async {
    final value=await ref.read(pinLockStoreProvider).read();
    if(!_allowed(generation))return false;
    if(value!=_pin){_retire();return false;}
    return true;
  }
  String _failure(Object error,AppLocalizations l10n,{bool decrypting=false}){
    if(error is DashboardStorageException){
      return switch(error.code){
        'scope_mismatch'=>l10n.coreLayoutArchiveWrongHome,
        'changed'=>l10n.coreLayoutArchiveChanged,
        'expired'=>l10n.coreLayoutArchiveExpired,
        _=>l10n.coreLayoutArchiveUncertain,
      };
    }
    if(error is CoreLayoutArchiveException && error.code=='unsupported_layout')return l10n.coreLayoutArchiveUnsupported;
    if(error is CoreLayoutArchiveCodecException && error.code=='invalid_passphrase')return l10n.coreLayoutArchiveInvalidPassword;
    if(decrypting)return l10n.coreLayoutArchiveDecryptFailed;
    return l10n.coreLayoutArchiveFileFailed;
  }
  void _reviewTop(){
    final generation=_generation;
    WidgetsBinding.instance.addPostFrameCallback((_){
      if(mounted && generation==_generation && _current() && _scroll.hasClients)_scroll.jumpTo(0);
    });
  }
  void _report(String message,{bool error=false}){_message=message;_error=error;_changed();_reviewTop();}
  Future<void> _load() async {
    if(_busy || !_bind())return;
    final generation=++_generation;_busy=true;_message=null;_rooms=null;_changed();
    try{
      final snapshot=await _controller!.capture();
      if(!_allowed(generation))return;
      _rooms=List.unmodifiable(snapshot.rooms.map((r)=>r.name));
    }catch(error){if(_allowed(generation))_report(_failure(error,AppLocalizations.of(context)),error:true);}
    finally{if(mounted && generation==_generation){_busy=false;_changed();}}
  }
  Future<T?> _fileOperation<T>(Future<T?> Function() operation) async {
    // No plaintext snapshot, password controller or old preview spans the OS UI.
    _fileDialog=true;_generation++;_discard();
    try{
      final result=await widget.runFileDialog<T>(() async {
        if(!_baseCurrent())return null;
        return await operation();
      });
      // Reauthentication unlocks the nested gate by rebuilding TickerMode.
      // Wait for that frame, then check every binding again without an exception.
      await WidgetsBinding.instance.endOfFrame;
      if(!_baseCurrent() || !_bind()){_retire();return null;}
      final generation=_generation;
      final current=await _controller!.capture();
      if(!_allowed(generation))return null;
      _rooms=List.unmodifiable(current.rooms.map((r)=>r.name));
      return result;
    }catch(_){
      if(_baseCurrent())_bind();
      rethrow;
    }finally{_fileDialog=false;if(mounted){_busy=false;_changed();}}
  }
  Future<void> _pick(int generation) async {
    if(_busy || !_allowed(generation))return;
    _busy=true;_message=null;_changed();
    final files=ref.read(coreLayoutArchiveFileAccessProvider);
    try{
      final bytes=await _fileOperation(files.pick);
      if(!_current())return;
      if(bytes==null){_report(AppLocalizations.of(context).coreLayoutArchiveCancelled);return;}
      if(bytes.isEmpty || bytes.length>CoreLayoutArchiveCodec.maxFileBytes)throw const CoreLayoutArchiveFileException();
      _file=Uint8List.fromList(bytes);_message=null;_changed();
    }catch(error){if(_current())_report(_failure(error,AppLocalizations.of(context)),error:true);}
    finally{if(mounted){_busy=false;_changed();}}
  }
  Future<void> _export(int generation) async {
    if(_busy || !_allowed(generation))return;
    final l10n=AppLocalizations.of(context);
    String? password=_password.text;
    try{CoreLayoutArchiveCodec.validatePassphrase(password,settingsPin:_pin);if(password!=_repeat.text)throw const CoreLayoutArchiveCodecException('invalid_passphrase');}
    catch(_){_report(l10n.coreLayoutArchiveInvalidPassword,error:true);return;}
    final operation=++_generation;var dispatchedFile=false;_busy=true;_message=null;_changed();
    try{
      if(!await _durablePin(operation))return;
      CoreLayoutArchiveV1? archive=await _controller!.capture();if(!_allowed(operation))return;
      final bytes=await ref.read(coreLayoutArchiveCodecProvider).encrypt(archive,password);
      archive=null;password=null;
      if(!_allowed(operation))return;
      final files=ref.read(coreLayoutArchiveFileAccessProvider);
      dispatchedFile=true;
      final saved=await _fileOperation(()=>files.save(bytes));
      if(_current())_report(saved==null?l10n.coreLayoutArchiveCancelled:l10n.coreLayoutArchiveSaved);
    }catch(error){if(dispatchedFile ? _current() : _allowed(operation))_report(_failure(error,l10n),error:true);}
    finally{if(mounted){_password.clear();_repeat.clear();_busy=false;_changed();}}
  }
  Future<void> _decrypt(int generation) async {
    if(_busy || !_allowed(generation) || _file==null)return;
    final bytes=Uint8List.fromList(_file!),password=_openPassword.text,l10n=AppLocalizations.of(context);
    final operation=++_generation;_busy=true;_preview=null;_message=null;_changed();
    try{
      if(!await _durablePin(operation))return;
      final archive=await ref.read(coreLayoutArchiveCodecProvider).decrypt(bytes,password);
      if(!_allowed(operation))return;
      final preview=await _controller!.preview(archive);if(!_allowed(operation))return;
      _preview=preview;_file=null;_reviewTop();
    }catch(error){if(_allowed(operation))_report(_failure(error,l10n,decrypting:true),error:true);}
    finally{if(mounted){_openPassword.clear();if(operation==_generation)_busy=false;_changed();}}
  }
  Future<void> _confirm(int generation) async {
    if(_busy || !_allowed(generation) || _preview==null)return;
    final preview=_preview!,l10n=AppLocalizations.of(context);
    final phase=++_generation;var answered=false;
    late final CupertinoDialogRoute<bool> route;
    void answer(bool value){if(answered || !identical(_dialog,route) || !_allowed(phase))return;answered=true;Navigator.of(context).pop(value);}
    route=CupertinoDialogRoute<bool>(context:context,builder:(_)=>CupertinoAlertDialog(
      title:Text(l10n.coreLayoutArchiveReplace),content:Text(l10n.coreLayoutArchiveConfirm),
      actions:[
        _ArchiveDialogAction(actionKey:const ValueKey('core-layout-archive-confirm-cancel'),onPressed:()=>answer(false),label:l10n.commonCancel),
        _ArchiveDialogAction(actionKey:const ValueKey('core-layout-archive-confirm'),isDestructiveAction:true,onPressed:()=>answer(true),label:l10n.coreLayoutArchiveReplace),
      ],
    ));
    _dialog=route;_changed();
    final accepted=await Navigator.of(context).push(route);
    if(identical(_dialog,route))_dialog=null;
    if(!_allowed(phase))return;
    _generation++;
    if(accepted!=true){_changed();return;}
    final operation=_generation;_busy=true;_preview=null;_message=null;_changed();
    try{
      if(!await _durablePin(operation))return;
      await _controller!.apply(preview);if(!_allowed(operation))return;
      _rooms=preview.archivedRoomNames;
      ref.invalidate(dashboardLayoutProvider);
      _report(l10n.coreLayoutArchiveApplied);
    }catch(error){if(_allowed(operation))_report(_failure(error,l10n),error:true);}
    finally{if(mounted && operation==_generation){_busy=false;_changed();}}
  }

  Widget _button(String key,String text,VoidCallback? action,{bool primary=false}){
    final theme=CupertinoTheme.of(context);
    final focusColor=CupertinoTheme.brightnessOf(context)==Brightness.dark?Color.lerp(theme.primaryColor,CupertinoColors.white,.12):theme.primaryColor;
    final child=Text(text,textAlign:TextAlign.center);
    return Semantics(container:true,child:Padding(padding:const EdgeInsets.all(8),child:primary?CupertinoButton.filled(key:ValueKey(key),minimumSize:const Size(48,48),focusColor:focusColor,onPressed:action,child:child):CupertinoButton(key:ValueKey(key),minimumSize:const Size(48,48),focusColor:focusColor,onPressed:action,child:child)));
  }
  Widget _field(String key,String label,TextEditingController controller)=>Padding(padding:const EdgeInsets.all(12),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
    ExcludeSemantics(child:Text(label)),const SizedBox(height:8),Semantics(label:label,child:CupertinoTextField(key:ValueKey(key),controller:controller,enabled:!_busy,obscureText:true,enableSuggestions:false,autocorrect:false,padding:const EdgeInsets.all(14))),
  ]));
  Widget _roomSection(String label,List<String> names,AppLocalizations l10n)=>SettingsSection(header:Semantics(container:true,header:true,child:Text(label)),children:[
    if(names.isEmpty)Padding(padding:const EdgeInsets.all(16),child:Text(l10n.coreLayoutArchiveEmpty)),
    for(final name in names)Padding(padding:const EdgeInsets.all(16),child:Align(alignment:AlignmentDirectional.centerStart,child:Text(name))),
  ]);

  @override Widget build(BuildContext context){
    final l10n=AppLocalizations.of(context),pin=ref.watch(pinLockProvider);
    if(!_pinResolved && !pin.isLoading && !pin.hasError && pin.hasValue){_pinResolved=true;_pin=pin.value;}
    ref.listen(pinLockProvider,(_,next){if(_pinResolved && (next.isLoading || next.hasError || !next.hasValue || next.value!=_pin))_retire();});
    ref.watch(homeSessionControllerProvider);
    ref.watch(dashboardRepositoryProvider);
    ref.watch(windowPolicySnapshotProvider);
    ref.listen(windowPolicySnapshotProvider,(_,next){
      if(!_started)return;
      if(next.isLoading || next.hasError || !next.hasValue || next.requireValue.supported && (!next.requireValue.isResumed || !next.requireValue.hasWindowFocus || next.requireValue.isPictureInPicture))_retire(permanent:!_fileDialog);
    });
    if(!_started && _baseCurrent()){
      _started=true;WidgetsBinding.instance.addPostFrameCallback((_){if(mounted)_load();});
    }
    if(_started && !_fileDialog && !_baseCurrent() && !_closed){WidgetsBinding.instance.addPostFrameCallback((_){if(mounted && !_fileDialog && !_baseCurrent())_retire();});}
    final enabled=!_busy && _current(),generation=_generation;
    return AppPageScaffold(key:const ValueKey('core-layout-archive-screen'),navigationBar:CupertinoNavigationBar(
      automaticallyImplyLeading:false,middle:Text(l10n.coreLayoutArchiveTitle),
    ),child:SafeArea(child:Center(child:ConstrainedBox(constraints:const BoxConstraints(maxWidth:780),child:ListView(controller:_scroll,padding:const EdgeInsets.symmetric(horizontal:12,vertical:20),children:[
      Align(alignment:AlignmentDirectional.centerStart,child:_button('core-layout-archive-back',l10n.commonBack,(){
        if(mounted && generation==_generation && _foreground && _focused && _windowCurrent() && (_interaction?.active??true) &&
          identical(ProviderScope.containerOf(context,listen:false),_container) &&
          widget.gateCurrent() && TickerMode.valuesOf(context).enabled && ModalRoute.of(context)?.isCurrent==true)Navigator.of(context).maybePop();
      })),
      Padding(padding:const EdgeInsets.all(12),child:Text(l10n.coreLayoutArchiveHint)),
      if(_closed)Padding(padding:const EdgeInsets.all(16),child:Text(l10n.coreLayoutArchiveExpired)) else ...[
        if(_message!=null)Padding(padding:const EdgeInsets.all(16),child:Semantics(liveRegion:true,child:Text(_message!,key:const ValueKey('core-layout-archive-message'),style:TextStyle(color:_error?CupertinoColors.systemRed.resolveFrom(context):CupertinoColors.label.resolveFrom(context))))),
        if(_busy)const Center(child:CupertinoActivityIndicator()),
        if(_preview case final preview?) ...[
          Column(key:const ValueKey('core-layout-archive-preview'),children:[_roomSection(l10n.coreLayoutArchiveCurrent,preview.currentRoomNames,l10n),_roomSection(l10n.coreLayoutArchiveSavedRooms,preview.archivedRoomNames,l10n)]),
          _button('core-layout-archive-replace',l10n.coreLayoutArchiveReplace,enabled?()=>_confirm(generation):null,primary:true),
        ] else ...[
          if(_rooms case final rooms?) _roomSection(l10n.coreLayoutArchiveCurrent,rooms,l10n),
          _button('core-layout-archive-refresh',l10n.coreLayoutArchiveRefresh,enabled?(){if(_allowed(generation))_load();}:null),
        ],
        SettingsSection(header:Semantics(container:true,header:true,child:Text(l10n.coreLayoutArchiveImport)),children:[
          _button('core-layout-archive-pick',l10n.coreLayoutArchiveImport,enabled?()=>_pick(generation):null),
          if(_file!=null)...[_field('core-layout-archive-open-password',l10n.coreLayoutArchivePassword,_openPassword),_button('core-layout-archive-decrypt',l10n.coreLayoutArchiveOpen,enabled?()=>_decrypt(generation):null,primary:true)],
        ]),
        SettingsSection(header:Semantics(container:true,header:true,child:Text(l10n.coreLayoutArchiveExport)),footer:Text(l10n.coreLayoutArchivePasswordHint),children:[
          _field('core-layout-archive-password',l10n.coreLayoutArchivePassword,_password),_field('core-layout-archive-repeat',l10n.coreLayoutArchiveRepeat,_repeat),
          _button('core-layout-archive-export',l10n.coreLayoutArchiveExport,enabled?()=>_export(generation):null,primary:true),
        ]),
      ],
    ])))));
  }
  @override void dispose(){
    _generation++;_timer?.cancel();_controller?.close();_home?.removeListener(_homeChanged);_interaction?.removeListener(_interactionChanged);WidgetsBinding.instance.removeObserver(this);
    _file=null;_preview=null;_password.dispose();_repeat.dispose();_openPassword.dispose();_scroll.dispose();super.dispose();
  }
}

/// Keep Cupertino dialog semantics and Enter/Space activation at large text sizes.
class _ArchiveDialogAction extends StatefulWidget {
  const _ArchiveDialogAction({required this.actionKey,required this.onPressed,required this.label,this.isDestructiveAction=false});
  final Key actionKey;final VoidCallback onPressed;final String label;final bool isDestructiveAction;
  @override State<_ArchiveDialogAction> createState()=>_ArchiveDialogActionState();
}
class _ArchiveDialogActionState extends State<_ArchiveDialogAction>{
  bool focused=false;
  @override Widget build(BuildContext context)=>CupertinoDialogAction(
    key:widget.actionKey,onPressed:widget.onPressed,isDestructiveAction:widget.isDestructiveAction,
    child:FocusableActionDetector(
      onShowFocusHighlight:(value)=>setState(()=>focused=value),
      shortcuts:const {SingleActivator(LogicalKeyboardKey.enter):ActivateIntent(),SingleActivator(LogicalKeyboardKey.space):ActivateIntent()},
      actions:{ActivateIntent:CallbackAction<ActivateIntent>(onInvoke:(_){widget.onPressed();return null;})},
      child:Semantics(button:true,enabled:true,label:widget.label,onTap:widget.onPressed,excludeSemantics:true,
        child:Container(constraints:const BoxConstraints(minHeight:48),alignment:Alignment.center,
          decoration:BoxDecoration(border:Border.all(width:2,color:focused?CupertinoTheme.of(context).primaryColor:CupertinoColors.transparent),borderRadius:BorderRadius.circular(4)),
          child:Text(widget.label),
        ),
      ),
    ),
  );
}
