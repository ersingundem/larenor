// Reproduce async configuration reloads with a retained previous value.
// ignore_for_file: invalid_use_of_internal_member
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/proxmox/data/models/proxmox_guest.dart';
import 'package:larenor/features/proxmox/data/models/proxmox_task.dart';
import 'package:larenor/features/proxmox/data/proxmox_client.dart';
import 'package:larenor/features/proxmox/data/proxmox_config.dart';
import 'package:larenor/features/proxmox/presentation/console/proxmox_console_screen.dart';
import 'package:larenor/features/proxmox/presentation/proxmox_node_detail_screen.dart';
import 'package:larenor/features/proxmox/presentation/proxmox_session_guard.dart';
import 'package:larenor/features/proxmox/presentation/proxmox_tasks_screen.dart';
import 'package:larenor/features/proxmox/providers/proxmox_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import '../dashboard/webview_tile_test.dart'
    show TestWebViewPlatform, TestWebViewPermission, TestWebViewSslError;
import 'proxmox_providers_test.dart' show ControlledConnection;
import 'proxmox_transport_security_test.dart'
    show fixtureConfig, authResponse, dataResponse;

const _guest = ProxmoxGuest(
  vmid: 101,
  name: 'Fixture guest',
  type: ProxmoxGuestType.qemu,
  node: 'pve',
  status: 'running',
);
const _other = ProxmoxConfig(
  host: 'other.example',
  port: 8006,
  username: 'other',
  realm: 'pam',
  password: 'fixture-only',
  allowSelfSigned: false,
);

class _Probe extends ConsumerStatefulWidget {
  const _Probe({super.key});
  @override
  ConsumerState<_Probe> createState() => _ProbeState();
}

class _ProbeState extends ProxmoxSessionState<_Probe> {
  int invalidations = 0;
  @override
  void onSessionInvalidated() {
    invalidations++;
  }

  @override
  Widget build(BuildContext context) {
    watchProxmoxSession();
    if (sessionAvailable) ref.watch(proxmoxClientProvider);
    return CupertinoPageScaffold(
      child: Text(sessionAvailable ? 'available' : 'unavailable'),
    );
  }
}

class _Connection extends ControlledConnection {
  _Connection(this.initial);
  final ProxmoxConfig initial;
  @override
  Future<ProxmoxConfig?> build() async => initial;
}

class _Harness {
  _Harness({ProxmoxConfig initial = fixtureConfig})
    : connection = _Connection(initial);
  final _Connection connection;
  final platform = TestWebViewPlatform();
  final requests = <http.Request>[];
  late ProviderContainer container;
  late AppLocalizations l10n;
  Future<http.Response> Function(http.Request)? response;
  Future<void> mount(WidgetTester tester, Widget home) async {
    final previous = WebViewPlatform.instance;
    WebViewPlatform.instance = platform;
    container = ProviderContainer(
      overrides: [
        proxmoxConnectionProvider.overrideWith(() => connection),
        proxmoxClientFactoryProvider.overrideWithValue(
          (config, health) => ProxmoxClient(
            config: config,
            healthSession: health,
            httpClient: MockClient((request) async {
              requests.add(request);
              if (request.url.path.endsWith('/access/ticket')) {
                return authResponse();
              }
              return response?.call(request) ?? Future.value(dataResponse([]));
            }),
          ),
        ),
        proxmoxGuestsProvider('pve').overrideWith((_) async => [_guest]),
        proxmoxStoragesProvider('pve').overrideWith((_) async => []),
        proxmoxTasksProvider('pve').overrideWith(
          (_) async => [
            const ProxmoxTask(upid: 'UPID:pve:fixture', type: 'backup'),
          ],
        ),
      ],
    );
    addTearDown(() {
      container.dispose();
      WebViewPlatform.instance = previous ?? TestWebViewPlatform();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: CupertinoApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              l10n = AppLocalizations.of(context);
              return home;
            },
          ),
        ),
      ),
    );
    await pump(tester);
  }

  Future<void> pump(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.pump();
  }

  void loading() => connection.replace(
    const AsyncLoading<ProxmoxConfig?>().copyWithPrevious(
      const AsyncData(fixtureConfig),
    ),
  );
}

void _pause(WidgetTester tester) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
}

void _resume(WidgetTester tester) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

void main() {
  testWidgets('hidden task list performs no read and releases polling demand', (
    tester,
  ) async {
    final h = _Harness();
    final visible = ValueNotifier(false);
    addTearDown(visible.dispose);
    await h.mount(
      tester,
      ValueListenableBuilder(
        valueListenable: visible,
        builder: (_, showing, _) => TickerMode(
          enabled: showing,
          child: const ProxmoxTasksScreen(nodeName: 'pve'),
        ),
      ),
    );
    expect(h.container.exists(proxmoxTasksProvider('pve')), isFalse);
    await tester.pump(const Duration(seconds: 30));
    expect(h.container.exists(proxmoxTasksProvider('pve')), isFalse);
    visible.value = true;
    await h.pump(tester);
    expect(find.text('backup'), findsOneWidget);
    visible.value = false;
    await h.pump(tester);
    expect(h.container.exists(proxmoxTasksProvider('pve')), isFalse);
    await tester.pump(const Duration(seconds: 30));
    expect(h.container.exists(proxmoxTasksProvider('pve')), isFalse);
    await h.close(tester);
  });

  testWidgets(
    'action lease invalidates on background, reload and account change',
    (tester) async {
      final h = _Harness();
      final key = GlobalKey<_ProbeState>();
      await h.mount(tester, _Probe(key: key));
      final state = key.currentState!;
      final initial = state.captureSession()!;
      expect(state.isSessionCurrent(initial), isTrue);
      _pause(tester);
      await h.pump(tester);
      expect(state.isSessionCurrent(initial), isFalse);
      _resume(tester);
      await h.pump(tester);
      expect(state.sessionAvailable, isTrue);
      expect(state.isSessionCurrent(initial), isFalse);
      final resumed = state.captureSession()!;
      h.loading();
      await h.pump(tester);
      expect(state.sessionAvailable, isFalse);
      expect(state.isSessionCurrent(resumed), isFalse);
      h.connection.replace(const AsyncData(fixtureConfig));
      await h.pump(tester);
      expect(state.sessionAvailable, isTrue);
      expect(state.isSessionCurrent(resumed), isFalse);
      final fresh = state.captureSession()!;
      h.connection.replace(const AsyncData(_other));
      await h.pump(tester);
      expect(state.sessionAvailable, isFalse);
      expect(state.isSessionCurrent(fresh), isFalse);
      h.connection.replace(const AsyncData(fixtureConfig));
      await h.pump(tester);
      expect(
        state.sessionAvailable,
        isFalse,
        reason:
            'A changed route must reopen, even if the original account returns',
      );
      await h.close(tester);
    },
  );

  testWidgets(
    'route source survives parent unmount but never follows new config',
    (tester) async {
      final h = _Harness();
      bool Function()? source;
      final visible = ValueNotifier(true);
      addTearDown(visible.dispose);
      await h.mount(
        tester,
        ValueListenableBuilder(
          valueListenable: visible,
          builder: (_, show, _) => show
              ? Consumer(
                  builder: (context, ref, _) {
                    ref.watch(proxmoxConnectionProvider);
                    source = captureProxmoxRouteSource(ref) ?? source;
                    return const Text('parent row');
                  },
                )
              : const Text('parent row retired'),
        ),
      );
      expect(source!(), isTrue);
      // The destination route's guard observes local configuration after the
      // origin row releases its own subscription.
      final childSubscription = h.container.listen(
        proxmoxConnectionProvider,
        (_, _) {},
      );
      addTearDown(childSubscription.close);
      visible.value = false;
      await h.pump(tester);
      expect(source!(), isTrue);
      h.loading();
      await h.pump(tester);
      expect(source!(), isFalse);
      h.connection.replace(const AsyncData(fixtureConfig));
      await h.pump(tester);
      expect(source!(), isTrue);
      h.connection.replace(const AsyncData(_other));
      await h.pump(tester);
      expect(source!(), isFalse);
      await h.close(tester);
      expect(source!(), isFalse);
    },
  );

  testWidgets(
    'console opens normal login URL with no API cookie, token or POST',
    (tester) async {
      final h = _Harness();
      await h.mount(tester, const ProxmoxConsoleScreen(guest: _guest));
      final web = h.platform.controllers.single;
      expect(web.requests, hasLength(1));
      final request = web.requests.single;
      expect(request.uri.origin, Uri.parse(fixtureConfig.baseUrl).origin);
      expect(request.uri.path, '/');
      expect(
        request.uri.queryParameters,
        isEmpty,
        reason:
            'Cold login uses the main interface, not a console-only template',
      );
      expect(request.headers, isEmpty);
      expect(request.body, isNull);
      expect(request.method, LoadRequestMethod.get);
      expect(request.uri.toString(), isNot(contains('ticket')));
      expect(find.text(h.l10n.proxmoxConsoleSignInRequired), findsOneWidget);
      expect(
        h.requests.where(
          (request) =>
              request.method != 'GET' &&
              !request.url.path.endsWith('/access/ticket'),
        ),
        isEmpty,
      );
      expect(
        tester.takeException(),
        isNull,
        reason: 'Fake has no cookie manager: cookie injection would fail',
      );
      final open = tester
          .widget<CupertinoButton>(
            find.ancestor(
              of: find.text(h.l10n.proxmoxConsoleOpenSession),
              matching: find.byType(CupertinoButton),
            ),
          )
          .onPressed!;
      open();
      open();
      await h.pump(tester);
      expect(h.platform.controllers, hasLength(2));
      final console = h.platform.controllers.last;
      expect(console.requests.single.uri.queryParameters['vmid'], '101');
      expect(console.requests.single.uri.queryParameters['node'], 'pve');
      expect(console.requests.single.uri.queryParameters['novnc'], '1');
      expect(console.requests.single.headers, isEmpty);
      expect(console.requests.single.body, isNull);
      web.delegate.finished(request.uri.toString());
      await h.pump(tester);
      expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
      await tester.tap(find.text(h.l10n.proxmoxConsoleWebSignIn));
      await h.pump(tester);
      expect(
        h.platform.controllers.last.requests.single.uri.queryParameters,
        isEmpty,
      );
      await h.close(tester);
      expect(web.modes.last, JavaScriptMode.disabled);
      expect(web.html, ['<html></html>']);
    },
  );

  testWidgets(
    'retained Open console button cannot load after account expires',
    (tester) async {
      final h = _Harness();
      await h.mount(tester, const ProxmoxConsoleScreen(guest: _guest));
      final open = tester
          .widget<CupertinoButton>(
            find.ancestor(
              of: find.text(h.l10n.proxmoxConsoleOpenSession),
              matching: find.byType(CupertinoButton),
            ),
          )
          .onPressed!;
      h.connection.replace(const AsyncData(_other));
      await h.pump(tester);
      open();
      await h.pump(tester);
      expect(h.platform.controllers, hasLength(1));
      expect(h.platform.controllers.single.html, ['<html></html>']);
      await h.close(tester);
    },
  );

  testWidgets(
    'console TLS always cancels, even when API self-signed option is enabled',
    (tester) async {
      final h = _Harness(
        initial: const ProxmoxConfig(
          host: 'proxmox.test',
          port: 8006,
          username: 'fixture',
          realm: 'pam',
          password: 'not-a-real-password',
          allowSelfSigned: true,
        ),
      );
      await h.mount(tester, const ProxmoxConsoleScreen(guest: _guest));
      expect(
        h.container.read(proxmoxConnectionProvider).value!.allowSelfSigned,
        isTrue,
      );
      final web = h.platform.controllers.single;
      final ssl = TestWebViewSslError();
      web.delegate.ssl(ssl);
      await h.pump(tester);
      expect(ssl.decisions, ['cancel']);
      expect(
        find.text(h.l10n.proxmoxConsoleTrustedTlsRequired),
        findsOneWidget,
      );
      expect(find.textContaining('private.invalid'), findsNothing);
      expect(web.html, ['<html></html>']);
      await h.close(tester);
    },
  );

  testWidgets(
    'console permissions denied, auth cancelled, navigation origin exact',
    (tester) async {
      final h = _Harness();
      await h.mount(tester, const ProxmoxConsoleScreen(guest: _guest));
      final web = h.platform.controllers.single;
      final permission = TestWebViewPermission();
      web.permission(permission);
      final auth = <String>[];
      web.delegate.auth(
        HttpAuthRequest(
          host: fixtureConfig.host,
          onProceed: (_) => auth.add('proceed'),
          onCancel: () => auth.add('cancel'),
        ),
      );
      await h.pump(tester);
      expect(permission.decisions, ['deny']);
      expect(auth, ['cancel']);
      final base = fixtureConfig.baseUrl;
      for (final target in ['$base/next', '$base/?console=kvm']) {
        expect(
          await web.delegate.navigation(
            NavigationRequest(url: target, isMainFrame: true),
          ),
          NavigationDecision.navigate,
        );
      }
      for (final target in [
        'https://other.example',
        '$base@other.example/',
        '${base.replaceFirst('https:', 'http:')}/',
        'file:///secret',
        '$base/%0aHeader',
        'https://user:secret@${fixtureConfig.host}:8006',
      ]) {
        expect(
          await web.delegate.navigation(
            NavigationRequest(url: target, isMainFrame: false),
          ),
          NavigationDecision.prevent,
        );
      }
      await h.close(tester);
    },
  );

  for (final transition in ['loading', 'account', 'background', 'unmount']) {
    testWidgets(
      'console delayed init after $transition cannot load stale guest',
      (tester) async {
        final h = _Harness();
        final gate = Completer<void>();
        h.platform.nextDelegateGate = gate;
        await h.mount(tester, const ProxmoxConsoleScreen(guest: _guest));
        final web = h.platform.controllers.single;
        expect(web.requests, isEmpty);
        switch (transition) {
          case 'loading':
            h.loading();
          case 'account':
            h.connection.replace(const AsyncData(_other));
          case 'background':
            _pause(tester);
          case 'unmount':
            await h.close(tester);
        }
        await h.pump(tester);
        gate.complete();
        await h.pump(tester);
        expect(web.requests, isEmpty);
        expect(web.html, ['<html></html>']);
        final ssl = TestWebViewSslError();
        web.delegate.ssl(ssl);
        web.delegate.finished('https://old.example');
        await h.pump(tester);
        expect(ssl.decisions, ['cancel']);
        expect(tester.takeException(), isNull);
        if (transition == 'background') _resume(tester);
        if (transition != 'unmount') await h.close(tester);
      },
    );
  }

  testWidgets(
    'node route hides old guests and disables retained navigation callbacks',
    (tester) async {
      final h = _Harness();
      await h.mount(tester, const ProxmoxNodeDetailScreen(nodeName: 'pve'));
      expect(find.text('Fixture guest'), findsOneWidget);
      final add = tester
          .widget<CupertinoButton>(
            find
                .ancestor(
                  of: find.byIcon(CupertinoIcons.add),
                  matching: find.byType(CupertinoButton),
                )
                .first,
          )
          .onPressed!;
      final count = h.requests.length;
      h.loading();
      await h.pump(tester);
      expect(find.text('Fixture guest'), findsNothing);
      add();
      await h.pump(tester);
      expect(find.text(h.l10n.proxmoxCreateFromTemplateTitle), findsNothing);
      expect(
        h.requests.length,
        count,
        reason: 'Expired navigation cannot start any request',
      );
      await h.close(tester);
    },
  );

  testWidgets(
    'task log account switch clears old lines and ignores late status',
    (tester) async {
      final h = _Harness();
      final status = Completer<http.Response>();
      h.response = (request) async => request.url.path.endsWith('/status')
          ? status.future
          : dataResponse([
              {'t': 'private old log'},
            ]);
      await h.mount(tester, const ProxmoxTasksScreen(nodeName: 'pve'));
      await tester.tap(find.text('backup'));
      await tester.pump(const Duration(seconds: 1));
      await h.pump(tester);
      expect(
        h.requests.where((request) => request.url.path.endsWith('/status')),
        hasLength(1),
      );
      h.connection.replace(const AsyncData(_other));
      await h.pump(tester);
      status.complete(dataResponse({'status': 'running'}));
      await h.pump(tester);
      expect(
        h.requests.where((request) => request.url.path.endsWith('/log')),
        isEmpty,
      );
      expect(find.textContaining('private old log'), findsNothing);
      expect(find.text(h.l10n.proxmoxSessionExpired), findsWidgets);
      await tester.pump(const Duration(seconds: 30));
      expect(
        h.requests.where((request) => request.url.host == _other.host),
        isEmpty,
      );
      await h.close(tester);
    },
  );

  testWidgets(
    'completed task log content is removed immediately on account change',
    (tester) async {
      final h = _Harness();
      h.response = (request) async => request.url.path.endsWith('/status')
          ? dataResponse({'status': 'stopped', 'exitstatus': 'OK'})
          : dataResponse([
              {'t': 'old account log line'},
            ]);
      await h.mount(tester, const ProxmoxTasksScreen(nodeName: 'pve'));
      await tester.tap(find.text('backup'));
      await tester.pump(const Duration(seconds: 1));
      await h.pump(tester);
      expect(find.text('old account log line'), findsOneWidget);
      h.connection.replace(const AsyncData(_other));
      await h.pump(tester);
      expect(find.text('old account log line'), findsNothing);
      expect(
        h.requests.where((request) => request.url.host == _other.host),
        isEmpty,
      );
      await h.close(tester);
    },
  );
}
