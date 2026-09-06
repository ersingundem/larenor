import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_discovery.dart';

class FakeJellyfinSocket implements RawDatagramSocket {
 final events=StreamController<RawSocketEvent>();int sends=0,closes=0;
 @override bool broadcastEnabled=false;
 @override int send(List<int> buffer,InternetAddress address,int port){sends++;expect(address.address,'255.255.255.255');expect(port,7359);return buffer.length;}
 @override void close(){closes++;events.close();}
 @override StreamSubscription<RawSocketEvent> listen(void Function(RawSocketEvent)? onData,{Function? onError,void Function()? onDone,bool? cancelOnError})=>events.stream.listen(onData,onError:onError,onDone:onDone,cancelOnError:cancelOnError);
 @override dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
void main(){
 for(final reason in ['stopped','source_lost']){
  test('discovery $reason during pending bind closes socket without broadcast',()async{
   final socket=FakeJellyfinSocket(),bound=Completer<RawDatagramSocket>();var current=true;
   final service=JellyfinDiscoveryService(bind:()=>bound.future);
   final pending=service.start(isCurrent:()=>current);
   if(reason=='stopped'){await service.stop();}else{current=false;}
   bound.complete(socket);await pending;expect(socket.sends,0);expect(socket.closes,1);await service.stop();
  });
 }
 test('discovery denied before start never asks the socket factory',()async{
  var binds=0;final socket=FakeJellyfinSocket();final service=JellyfinDiscoveryService(bind:()async{binds++;return socket;});
  await service.start(isCurrent:()=>false);expect(binds,0);expect(socket.sends,0);await service.stop();
 });
 test('current Direct discovery broadcasts once and closes on stop',()async{
  final socket=FakeJellyfinSocket();final service=JellyfinDiscoveryService(bind:()async=>socket);
  await service.start(isCurrent:()=>true);expect(socket.sends,1);expect(socket.broadcastEnabled,isTrue);await service.stop();expect(socket.closes,1);
 });
}
