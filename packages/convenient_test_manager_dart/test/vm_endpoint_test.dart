import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:convenient_test_manager_dart/services/real_vm_service_wrapper_service.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

void main() {
  test(
    'connect preserves dynamic URI paths and switches active endpoints',
    () async {
      final first = await _VmEndpoint.start('/first-auth/ws');
      final second = await _VmEndpoint.start('/dds/session-token/ws');
      final wrapper = RealVmServiceWrapperService(autoConnect: false);
      addTearDown(() async {
        await wrapper.disconnect();
        await first.close();
        await second.close();
      });

      await wrapper.connect(uri: first.uri);
      await _waitUntil(() => wrapper.hotRestartAvailable);
      expect(wrapper.connected, isTrue);
      expect(first.requestPaths, contains('/first-auth/ws'));

      await wrapper.connect(uri: second.uri);
      await _waitUntil(() => wrapper.hotRestartAvailable);

      expect(wrapper.connected, isTrue);
      expect(second.requestPaths, contains('/dds/session-token/ws'));
      await wrapper.hotRestartRaw();
      expect(second.requestedMethods, contains('ext.flutter.hotRestart'));
      expect(first.requestedMethods, isNot(contains('ext.flutter.hotRestart')));
    },
  );

  test(
    'a failed endpoint can be retried and disconnect is repeatable',
    () async {
      final reservation = await ServerSocket.bind('127.0.0.1', 0);
      final unavailableUri = Uri.parse(
        'ws://127.0.0.1:${reservation.port}/unavailable/ws',
      );
      await reservation.close();

      final endpoint = await _VmEndpoint.start('/retry/ws');
      final wrapper = RealVmServiceWrapperService(autoConnect: false);
      addTearDown(() async {
        await wrapper.disconnect();
        await endpoint.close();
      });

      await wrapper.connect(uri: unavailableUri);
      expect(wrapper.connected, isFalse);

      await wrapper.connect(uri: endpoint.uri);
      expect(wrapper.connected, isTrue);

      await wrapper.disconnect();
      await wrapper.disconnect();
      expect(wrapper.connected, isFalse);
    },
  );

  test(
    'disconnect cancels stalled initialization and permits reconnect',
    () async {
      final stalled = await _VmEndpoint.start(
        '/stalled/ws',
        withheldMethods: <String>{'streamListen'},
      );
      final healthy = await _VmEndpoint.start('/healthy/ws');
      final wrapper = RealVmServiceWrapperService(autoConnect: false);
      addTearDown(() async {
        await stalled.close();
        await healthy.close();
        await wrapper.disconnect();
      });

      final stalledConnect = wrapper.connect(uri: stalled.uri);
      await _waitUntil(() => stalled.requestedMethods.contains('streamListen'));

      await wrapper.disconnect().timeout(const Duration(milliseconds: 200));
      await _waitUntil(() => stalled.clientDisconnected);
      expect(wrapper.connected, isFalse);

      await stalledConnect;
      await wrapper.connect(uri: healthy.uri);
      expect(wrapper.connected, isTrue);
    },
  );

  test('connect keeps an omitted URI as a compile-time optional argument', () {
    final wrapper = RealVmServiceWrapperService(autoConnect: false);
    addTearDown(wrapper.disconnect);

    final Future<void> Function({Uri? uri}) connect = wrapper.connect;
    expect(connect, isNotNull);
  });

  test(
    'disconnect disposes a client returned by a cancelled connector',
    () async {
      final connectorResult = Completer<VmService>();
      var connectorStarted = false;
      String? requestedUri;
      final wrapper = RealVmServiceWrapperService(
        autoConnect: false,
        connectionTimeout: const Duration(seconds: 1),
        vmServiceConnector: (uri) {
          connectorStarted = true;
          requestedUri = uri;
          return connectorResult.future;
        },
      );
      final lateClient = _ControllableVmService();
      addTearDown(() async {
        await wrapper.disconnect();
        await lateClient.finishDisposal();
      });

      final connect = wrapper.connect(
        uri: Uri.parse('ws://remote.example:9321/auth-token/ws'),
      );
      await _waitUntil(() => connectorStarted);

      await wrapper.disconnect().timeout(const Duration(milliseconds: 200));
      expect(wrapper.connected, isFalse);

      connectorResult.complete(lateClient);
      await connect;
      expect(lateClient.disposeCount, 1);
      expect(requestedUri, 'ws://remote.example:9321/auth-token/ws');
      expect(wrapper.connected, isFalse);
    },
  );

  test('connection timeout disposes a client that arrives later', () async {
    final connectorResult = Completer<VmService>();
    final wrapper = RealVmServiceWrapperService(
      autoConnect: false,
      connectionTimeout: const Duration(milliseconds: 20),
      vmServiceConnector: (_) => connectorResult.future,
    );
    final lateClient = _ControllableVmService();
    addTearDown(() async {
      await wrapper.disconnect();
      await lateClient.finishDisposal();
    });

    await wrapper
        .connect(uri: Uri.parse('ws://remote.example:9321/timeout/ws'))
        .timeout(const Duration(milliseconds: 200));
    expect(wrapper.connected, isFalse);

    connectorResult.complete(lateClient);
    await _waitUntil(() => lateClient.disposeCount == 1);
    expect(wrapper.connected, isFalse);
  });

  test(
    'late events and completion from a detached generation are ignored',
    () async {
      final first = _ControllableVmService(deferDispose: true);
      final second = _ControllableVmService();
      final manager = ServiceConnectionManager();
      addTearDown(() async {
        await manager.disconnect();
        await first.finishDisposal();
        await second.finishDisposal();
      });

      await manager.vmServiceOpened(first);
      await manager.vmServiceOpened(second);

      first.emitServiceRegistered();
      await first.finishDisposal();
      await Future<void>.delayed(Duration.zero);

      expect(manager.connected, isTrue);
      expect(
        manager.registeredMethodsForService,
        isNot(contains('hotRestart')),
      );
    },
  );
}

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Condition was not satisfied before the deadline');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _VmEndpoint {
  _VmEndpoint._(this._server, this._expectedPath, this._withheldMethods) {
    _requestSubscription = _server.listen(_handleRequest);
  }

  static Future<_VmEndpoint> start(
    String path, {
    Set<String> withheldMethods = const <String>{},
  }) async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    return _VmEndpoint._(server, path, withheldMethods);
  }

  final HttpServer _server;
  final String _expectedPath;
  final Set<String> _withheldMethods;
  late final StreamSubscription<HttpRequest> _requestSubscription;
  final _sockets = <WebSocket>[];

  final requestPaths = <String>[];
  final requestedMethods = <String>[];

  bool get clientDisconnected => _sockets.isEmpty;

  Uri get uri => Uri.parse('ws://127.0.0.1:${_server.port}$_expectedPath');

  Future<void> _handleRequest(HttpRequest request) async {
    requestPaths.add(request.uri.path);
    final socket = await WebSocketTransformer.upgrade(request);
    _sockets.add(socket);
    socket.listen(
      (message) => _handleMessage(socket, message as String),
      onDone: () => _sockets.remove(socket),
    );
  }

  void _handleMessage(WebSocket socket, String message) {
    final request = jsonDecode(message) as Map<String, dynamic>;
    final method = request['method'] as String;
    requestedMethods.add(method);
    if (_withheldMethods.contains(method)) return;

    final result = switch (method) {
      'getVM' => _vmResponse,
      'getIsolate' => _isolateResponse,
      _ => const <String, Object?>{'type': 'Success'},
    };
    socket.add(
      jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': request['id'],
        'result': result,
      }),
    );

    if (method == 'streamListen' &&
        (request['params'] as Map<String, dynamic>)['streamId'] == 'Service') {
      socket.add(jsonEncode(_serviceRegisteredEvent));
    }
  }

  Future<void> close() async {
    await _requestSubscription.cancel();
    await Future.wait([
      for (final socket in [..._sockets]) socket.close(),
    ]);
    await _server.close(force: true);
  }
}

const _isolateRef = <String, Object?>{
  'type': '@Isolate',
  'id': 'isolates/1',
  'number': '1',
  'name': 'main',
  'isSystemIsolate': false,
  'isolateGroupId': 'isolateGroups/1',
};

const _vmResponse = <String, Object?>{
  'type': 'VM',
  'name': 'test-vm',
  'architectureBits': 64,
  'hostCPU': 'arm64',
  'operatingSystem': 'macos',
  'targetCPU': 'arm64',
  'version': 'test',
  'pid': 1,
  'startTime': 0,
  'isolates': <Object?>[_isolateRef],
  'isolateGroups': <Object?>[],
  'systemIsolates': <Object?>[],
  'systemIsolateGroups': <Object?>[],
};

const _isolateResponse = <String, Object?>{
  'type': 'Isolate',
  'id': 'isolates/1',
  'number': '1',
  'name': 'main',
  'isSystemIsolate': false,
  'isolateGroupId': 'isolateGroups/1',
  'runnable': true,
  'extensionRPCs': <String>['ext.flutter.test'],
  'pauseEvent': <String, Object?>{
    'type': 'Event',
    'kind': 'Resume',
    'timestamp': 0,
  },
};

const _serviceRegisteredEvent = <String, Object?>{
  'jsonrpc': '2.0',
  'method': 'streamNotify',
  'params': <String, Object?>{
    'streamId': 'Service',
    'event': <String, Object?>{
      'type': 'Event',
      'kind': 'ServiceRegistered',
      'timestamp': 0,
      'service': 'hotRestart',
      'method': 'ext.flutter.hotRestart',
    },
  },
};

class _ControllableVmService extends VmService {
  factory _ControllableVmService({bool deferDispose = false}) {
    // Owned by the returned service and closed by [finishDisposal].
    // ignore: close_sinks
    final incoming = StreamController<String>();
    return _ControllableVmService._(incoming, deferDispose: deferDispose);
  }

  _ControllableVmService._(
    StreamController<String> incoming, {
    required this.deferDispose,
  }) : _incoming = incoming,
       super(
         incoming.stream,
         (message) => _respondToVmRequest(incoming, message),
       );

  final StreamController<String> _incoming;
  final bool deferDispose;
  bool _finishRequested = false;
  bool _incomingClosed = false;
  int disposeCount = 0;

  void emitServiceRegistered() {
    if (!_incomingClosed) _incoming.add(jsonEncode(_serviceRegisteredEvent));
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
    if (deferDispose && !_finishRequested) return;
    await super.dispose();
  }

  Future<void> finishDisposal() async {
    _finishRequested = true;
    await super.dispose();
    if (!_incomingClosed) {
      _incomingClosed = true;
      await _incoming.close();
    }
  }
}

void _respondToVmRequest(StreamController<String> incoming, String message) {
  final request = jsonDecode(message) as Map<String, dynamic>;
  final result = request['method'] == 'getVM'
      ? const <String, Object?>{
          'type': 'VM',
          'name': 'controlled-vm',
          'isolates': <Object?>[],
        }
      : const <String, Object?>{'type': 'Success'};
  incoming.add(
    jsonEncode(<String, Object?>{
      'jsonrpc': '2.0',
      'id': request['id'],
      'result': result,
    }),
  );
}
