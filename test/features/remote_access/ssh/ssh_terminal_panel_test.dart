import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../remote_profiles_ui_fixture.dart';
import 'ssh_session_controller_test.dart' show Engine;
void main(){
 testWidgets('saved personal SSH profile exposes an explicit terminal under actual PIN settings', (t) async {
   final ui=RemoteUi();final engine=Engine();await ui.mount(t,pin:true,sshEngine:()=>engine);await ui.edit(t);await ui.save(t);await ui.openFirst(t);
   expect(key('remote-ssh-open'),findsOneWidget);await press(t,'remote-ssh-open');
   expect(key('ssh-password'),findsOneWidget);expect(engine.opens,0);
 });
}
