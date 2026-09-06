import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/home_scope/data/core_layout_archive_codec.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import '../home_resources/home_resources_tablet_test.dart' show loadFonts;
import 'core_layout_archive_ui_fixture.dart';
import 'core_layout_archive_screen_test.dart' show archive,passphrase,importArchive;

Future<void> capture(WidgetTester tester, ArchiveHarness h,String name) async {
  const output=String.fromEnvironment('CORE_LAYOUT_ARCHIVE_PREVIEW_DIR');
  if(output.isEmpty)return;
  await tester.runAsync(() async {
    final render=h.boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image=await render.toImage(pixelRatio:1);
    try{
      final bytes=await image.toByteData(format:ui.ImageByteFormat.png);
      Directory(output).createSync(recursive:true);
      File('$output/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    }finally{image.dispose();}
  });
}
void main(){
  late Uint8List encrypted;
  setUpAll(() async { encrypted=await const CoreLayoutArchiveCodec().encrypt(archive(),passphrase); });
  for(final language in ['en','tr']) {
    for(final width in [320.0,600.0,1280.0]) {
      testWidgets('Core archive $language $width 2x has named 48px fields, keyboard and isolated confirmation',(tester) async {
        await loadFonts(tester);
        final semantics=tester.ensureSemantics();
        try{
        tester.platformDispatcher.platformBrightnessTestValue=width==1280?Brightness.dark:Brightness.light;
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        final h=ArchiveHarness();await h.mount(tester,language:language,width:width,scale:2);await h.open(tester,language:language);
        expect(tester.getSize(find.byKey(const ValueKey('core-layout-archive-back'))).height,greaterThanOrEqualTo(48));
        final pick=find.byKey(const ValueKey('core-layout-archive-pick'));
        await archiveVisible(tester,'core-layout-archive-pick');
        final l10n=AppLocalizations.of(tester.element(pick));
        final text=find.descendant(of:pick,matching:find.text(l10n.coreLayoutArchiveImport));
        final node=tester.getSemantics(text);
        expect(node.label,l10n.coreLayoutArchiveImport);expect(node.flagsCollection.isButton,isTrue);expect(node.rect.height,greaterThanOrEqualTo(48));
        Focus.of(tester.element(text)).requestFocus();await flush(tester);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);await tester.sendKeyEvent(LogicalKeyboardKey.tab);await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);await flush(tester);
        expect(Focus.of(tester.element(find.text(l10n.coreLayoutArchiveRefresh))).hasPrimaryFocus,isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);await flush(tester);
        expect(Focus.of(tester.element(text)).hasPrimaryFocus,isTrue);
        final decorations=find.descendant(of:pick,matching:find.byWidgetPredicate((w)=>w is DecoratedBox && w.decoration is ShapeDecoration && (w.decoration as ShapeDecoration).shape is OutlinedBorder));
        final outline=(tester.widget<DecoratedBox>(decorations.first).decoration as ShapeDecoration).shape as OutlinedBorder;
        final background=CupertinoDynamicColor.resolve(CupertinoTheme.of(tester.element(pick)).scaffoldBackgroundColor,tester.element(pick));
        final color=Color.alphaBlend(outline.side.color,background);
        final a=color.computeLuminance(),b=background.computeLuminance();
        expect(((a>b?a:b)+.05)/((a<b?a:b)+.05),greaterThanOrEqualTo(3));
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);await flush(tester);expect(h.files.picks,1);
        await importArchive(tester,h,encrypted);
        await archivePress(tester,'core-layout-archive-replace');
        expect(find.byType(CupertinoAlertDialog),findsOneWidget);
        final confirm=find.byKey(const ValueKey('core-layout-archive-confirm'));
        expect(tester.getSize(confirm).height,greaterThanOrEqualTo(48));
        final root=tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!;
        final labels=<String>[];
        void visit(SemanticsNode node){labels.add(node.label);node.visitChildren((child){visit(child);return true;});}
        visit(root);
        expect(labels.any((label)=>label.contains(l10n.coreLayoutArchiveConfirm)),isTrue);
        expect(labels.any((label)=>label.contains(l10n.coreLayoutArchivePasswordHint)),isFalse);
        await capture(tester,h,'archive-confirm-$language-${width.toInt()}-2x');
        final cancel=find.descendant(of:find.byKey(const ValueKey('core-layout-archive-confirm-cancel')),matching:find.byType(Text));
        Focus.of(tester.element(cancel)).requestFocus();await flush(tester);await tester.sendKeyEvent(LogicalKeyboardKey.enter);await flush(tester);
        expect(find.byType(CupertinoAlertDialog),findsNothing);
        await archivePress(tester,'core-layout-archive-replace');
        Focus.of(tester.element(find.descendant(of:confirm,matching:find.byType(Text)))).requestFocus();await flush(tester);await tester.sendKeyEvent(LogicalKeyboardKey.enter);await flush(tester);
        expect(find.text(l10n.coreLayoutArchiveApplied),findsOneWidget);
        h.files.input=null;
        await archivePress(tester,'core-layout-archive-pick');
        // Native cancellation drops the former preview. Export remains an explicit action.
        final password=find.byKey(const ValueKey('core-layout-archive-password'));
        await tester.scrollUntilVisible(password,250,scrollable:find.byType(Scrollable).first);
        await tester.ensureVisible(password);await flush(tester);
        expect(tester.getSize(password).height,greaterThanOrEqualTo(48));
        expect(tester.getSemantics(password).label,contains(l10n.coreLayoutArchivePassword));
        await tester.enterText(password,'synthetic new password');
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);await flush(tester);
        final repeated=tester.widget<EditableText>(find.descendant(of:find.byKey(const ValueKey('core-layout-archive-repeat')),matching:find.byType(EditableText)));
        expect(repeated.focusNode.hasFocus,isTrue);
        await tester.testTextInput.receiveAction(TextInputAction.done);await flush(tester);
        await capture(tester,h,'archive-form-$language-${width.toInt()}-2x');
        expect(tester.takeException(),isNull);expect(h.files.saves,0);
        }finally{semantics.dispose();}
      });
    }
  }
}
