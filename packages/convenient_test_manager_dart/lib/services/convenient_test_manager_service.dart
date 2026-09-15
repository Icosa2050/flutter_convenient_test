import 'dart:async';

import 'package:convenient_test_common_dart/convenient_test_common_dart.dart';
import 'package:convenient_test_manager_dart/services/report_handler_service.dart';
import 'package:convenient_test_manager_dart/services/report_saver_service.dart';
import 'package:convenient_test_manager_dart/stores/worker_super_run_store.dart';
import 'package:get_it/get_it.dart';
import 'package:grpc/grpc.dart' as grpc;
import 'package:grpc/grpc.dart';
import 'package:synchronized/synchronized.dart';

class ConvenientTestManagerService extends ConvenientTestManagerServiceBase {
  static const _kTag = 'ConvenientTestManagerService';

  final _serverLock = Lock();
  grpc.Server? _server;

  int? get boundPort => _server?.port;

  /// Starts one owned listener and returns its actual bound port.
  ///
  /// Calling this while the listener is active is idempotent and returns the
  /// active port, regardless of the newly requested address or port.
  Future<int> serve({
    int port = kConvenientTestManagerPort,
    String address = '0.0.0.0',
  }) => _serverLock.synchronized(() async {
    final activePort = _server?.port;
    if (activePort != null) return activePort;

    final server = grpc.Server.create(
      services: [this],
      errorHandler: _responseErrorHandler,
    );
    try {
      await server.serve(address: address, port: port);
    } catch (_) {
      await server.shutdown();
      rethrow;
    }

    final boundPort = server.port;
    if (boundPort == null) {
      await server.shutdown();
      throw StateError('gRPC server completed startup without a bound port');
    }
    _server = server;
    return boundPort;
  });

  Future<void> shutdown() => _serverLock.synchronized(() async {
    final server = _server;
    if (server == null) return;

    await server.shutdown();
    if (identical(_server, server)) _server = null;
  });

  @override
  Future<Empty> report(ServiceCall call, ReportCollection request) async {
    await reportInner(request);
    return Empty();
  }

  // https://github.com/fzyzcjy/yplusplus/issues/8537#issuecomment-1529669555
  final _reportLock = Lock();

  /// [report()] but without a [ServiceCall]
  Future<void> reportInner(ReportCollection request) async {
    await _reportLock.synchronized(() async {
      await GetIt.I.get<ReportHandlerService>().handle(
        request,
        offlineFile: false,
      );

      // NOTE *first* handle by ReportHandlerService, *then* by ReportSaverService,
      //      because ReportHandlerService may let ReportSaverService change target file
      await GetIt.I.get<ManagerReportSaverService>().save(request);
    });
  }

  @override
  Future<WorkerCurrentRunConfig> getWorkerCurrentRunConfig(
    grpc.ServiceCall call,
    Empty request,
  ) async {
    final ans = _workerSuperRunStore.calcCurrentRunConfig();
    Log.d(
      _kTag,
      'getWorkerCurrentRunConfig ans=$ans currSuperRunController=${_workerSuperRunStore.currSuperRunController}',
    );
    return ans;
  }

  static void _responseErrorHandler(Object? error, Object? stackTrace) {
    Log.e(
      _kTag,
      'error when handling grpc requests. error=$error stack=$stackTrace',
    );
  }

  final _workerSuperRunStore = GetIt.I.get<WorkerSuperRunStore>();
}
