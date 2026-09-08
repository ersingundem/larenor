import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/core/home_source_store.dart';
import '../core_ha_models_test.dart' show resourceJson,scopeJson;

import '../core_ha_api_test.dart' show response;
import 'transfer_api_test.dart' show transferReceiptJson;
import 'transfer_controller_fixture.dart';

void main() {
  testWidgets('resource permission loss clears the cached transfer choices before credential read', (tester) async {
    final h=TransferHarness();await h.mount(tester);final c=h.controller!;await c.load();
    h.reply=(_) async=>response({'error':{'code':'forbidden'}},403);
    await c.prepare(c.items.single,c.entities.single,isCurrent:()=>true);
    expect(c.failure,'forbidden');expect(c.items,isEmpty);expect(c.entities,isEmpty);
    expect(h.platform.calls,isEmpty);
  });
  testWidgets('room-only pagination counts toward the 512 global record bound', (tester) async {
    final h=TransferHarness();await h.mount(tester);final c=h.controller!;var offset=0;
    h.reply=(r) async {
      final count=offset==500?13:25;
      final entries=List.generate(count,(i) {
        final v=jsonDecode(jsonEncode(resourceJson())) as Map<String,dynamic>;
        (v['ref'] as Map)..['kind']='room'..['id']=(offset+i+1).toRadixString(16).padLeft(32,'0');return v;
      });offset+=count;
      return response({'scope':scopeJson(),'entries':entries,'snapshot':'a'*64,'nextAfter':offset==513?null:(entries.last['ref'] as Map)['id']});
    };
    await c.load();for(var i=0;i<20;i++){await c.load(more:true);}
    expect(offset,513);expect(c.failure,'invalid_response');expect(c.loaded,isFalse);expect(c.nextAfter,isNull);
    expect(h.platform.calls,isEmpty);
  });
  testWidgets(
    'mounted Direct provider loads local switches and Core choices without reading credentials',
    (tester) async {
      final h = TransferHarness();
      await h.mount(tester);
      final c = h.controller!;
      await c.load();
      expect(c.entities, ['switch.reading_lamp']);
      expect(c.items.single.label, 'Reading lamp');
      expect(h.platform.calls, isEmpty);
      expect(h.requests.single.method, 'GET');
    },
  );
  testWidgets(
    'explicit preview and confirm preserve local records and bind once',
    (tester) async {
      final h = TransferHarness();
      await h.mount(tester);
      final c = h.controller!;
      await c.load();
      await c.prepare(c.items.single, c.entities.single, isCurrent: () => true);
      final p = c.preview!;
      expect(h.platform.calls.length, 3);
      await c.confirm(p, isCurrent: () => true);
      expect(c.receipt?.requestId, p.requestId);
      expect(h.platform.calls.length, 6);
      expect(h.platform.calls.every((c) => c.$1 == 'read'), isTrue);
      await c.confirm(p, isCurrent: () => true);
      expect(
        h.requests.where((r) => r.url.path.endsWith('/confirm')).length,
        1,
      );
    },
  );
  testWidgets('lost confirm ACK recovers via explicit GET only', (
    tester,
  ) async {
    final h = TransferHarness();
    await h.mount(tester);
    final c = h.controller!;
    await c.load();
    await c.prepare(c.items.single, c.entities.single, isCurrent: () => true);
    h.reply = (_) async => response({
      'error': {'code': 'server_error'},
    }, 503);
    await c.confirm(c.preview!, isCurrent: () => true);
    expect(c.uncertain, isTrue);
    expect(c.receipt, isNull);
    final reads = h.platform.calls.length;
    h.reply = (r) async {
      expect(r.method, 'GET');
      return response({'receipt': transferReceiptJson()});
    };
    await c.recover(isCurrent: () => true);
    expect(c.uncertain, isFalse);
    expect(c.receipt, isNotNull);
    expect(h.platform.calls.length, reads);
    expect(h.requests.where((r) => r.url.path.endsWith('/confirm')).length, 1);
  });
  testWidgets(
    'Core source cold transfer reads no local credentials or network',
    (tester) async {
      final h = TransferHarness();
      await h.mount(tester, source: HomeSource.verifiedCore);
      await h.controller!.load();
      expect(h.platform.calls, isEmpty);
      expect(h.requests, isEmpty);
    },
  );
  testWidgets(
    'PIN retired between platform URL and token stops token and outbound',
    (tester) async {
      final h = TransferHarness();
      await h.mount(tester);
      final c = h.controller!;
      await c.load();
      h.platform.afterRead = (key) async {
        if (key == 'ha_base_url') {
          h.auth.pin = false;
          h.owner.synchronize();
        }
      };
      await c.prepare(c.items.single, c.entities.single, isCurrent: () => true);
      expect(h.platform.calls.map((e) => e.$2), [
        'ha_connection_pending_v1',
        'ha_base_url',
      ]);
      expect(h.requests.where((r) => r.method == 'POST'), isEmpty);
      expect(c.preview, isNull);
      expect(c.items, isEmpty);
    },
  );
  testWidgets('retired same account late401 cannot logout Core account', (
    tester,
  ) async {
    final h = TransferHarness();
    await h.mount(tester);
    final c = h.controller!;
    final reply = Completer<http.Response>();
    h.reply = (_) => reply.future;
    final load = c.load();
    await tester.pump();
    expect(h.requests.length, 1);
    h.auth.route = false;
    h.owner.synchronize();
    reply.complete(
      response({
        'error': {'code': 'unauthorized'},
      }, 401),
    );
    await load;
    expect(h.auth.account.session, isNotNull);
    expect(c.items, isEmpty);
  });
  testWidgets('active current401 still rejects the real Core account', (
    tester,
  ) async {
    final h = TransferHarness();
    await h.mount(tester);
    h.reply = (_) async => response({
      'error': {'code': 'unauthorized'},
    }, 401);
    await h.controller!.load();
    expect(h.requests.length, 1);
    expect(h.auth.account.session, isNull);
  });
  testWidgets(
    'preview TTL subtracts network duration and never exposes expired data',
    (tester) async {
      final h = TransferHarness();
      await h.mount(tester);
      final c = h.controller!;
      await c.load();
      h.reply = (r) async {
        h.reply = null;
        final result = await h.handle(r);
        if (r.url.path.endsWith('/preview')) {
          h.elapsed += const Duration(seconds: 61);
        }
        return result;
      };
      // Delay at the exact preview reply, after the metadata and binding GETs.
      final base = h.handle;
      h.reply = (r) async {
        final handler = h.reply;
        h.reply = null;
        final value = await base(r);
        h.reply = handler;
        if (r.url.path.endsWith('/preview')) {
          h.elapsed += const Duration(seconds: 61);
        }
        return value;
      };
      await c.prepare(c.items.single, c.entities.single, isCurrent: () => true);
      expect(c.preview, isNull);
      expect(c.failure, 'ha_migration_preview_invalid');
      expect(h.platform.calls.length, 3);
    },
  );
  testWidgets('expiry during confirmed POST may commit and must not replay', (
    tester,
  ) async {
    final h = TransferHarness();
    await h.mount(tester);
    final c = h.controller!;
    await c.load();
    await c.prepare(c.items.single, c.entities.single, isCurrent: () => true);
    final p = c.preview!;
    h.reply = (_) async {
      h.elapsed += const Duration(seconds: 61);
      return response({'receipt': transferReceiptJson()}, 201);
    };
    await c.confirm(p, isCurrent: () => true);
    expect(c.receipt, isNotNull);
    expect(c.uncertain, isFalse);
    await c.confirm(p, isCurrent: () => true);
    expect(h.requests.where((r) => r.url.path.endsWith('/confirm')).length, 1);
  });
  testWidgets(
    'changed local token before confirm yields zero POST and no pair writes',
    (tester) async {
      final h = TransferHarness();
      await h.mount(tester);
      final c = h.controller!;
      await c.load();
      await c.prepare(c.items.single, c.entities.single, isCurrent: () => true);
      h.platform.values['ha_token'] = 'replacement';
      await c.confirm(c.preview!, isCurrent: () => true);
      expect(c.failure, 'ha_migration_changed');
      expect(c.uncertain, isFalse);
      expect(h.requests.where((r) => r.url.path.endsWith('/confirm')), isEmpty);
      expect(h.platform.calls.every((c) => c.$1 == 'read'), isTrue);
    },
  );
  testWidgets('confirm expiry between URL and token stops token and outbound', (
    tester,
  ) async {
    final h = TransferHarness();
    await h.mount(tester);
    final c = h.controller!;
    await c.load();
    await c.prepare(c.items.single, c.entities.single, isCurrent: () => true);
    final old = h.platform.calls.length;
    h.platform.afterRead = (key) async {
      if (key == 'ha_base_url') h.elapsed += const Duration(seconds: 61);
    };
    await c.confirm(c.preview!, isCurrent: () => true);
    expect(h.platform.calls.skip(old).map((e) => e.$2), [
      'ha_connection_pending_v1',
      'ha_base_url',
    ]);
    expect(h.requests.where((r) => r.url.path.endsWith('/confirm')), isEmpty);
    expect(c.uncertain, isFalse);
  });
  testWidgets('missing recovery result remains uncertain without a new POST', (
    tester,
  ) async {
    final h = TransferHarness();
    await h.mount(tester);
    final c = h.controller!;
    await c.load();
    await c.prepare(c.items.single, c.entities.single, isCurrent: () => true);
    h.reply = (_) async => response({
      'error': {'code': 'server_error'},
    }, 503);
    await c.confirm(c.preview!, isCurrent: () => true);
    h.reply = (_) async => response({
      'error': {'code': 'not_found'},
    }, 404);
    await c.recover(isCurrent: () => true);
    expect(c.uncertain, isTrue);
    expect(c.canRecover, isTrue);
    expect(c.failure, 'not_found');
    await c.load();
    expect(h.requests.where((r) => r.url.path.endsWith('/confirm')).length, 1);
  });
}
