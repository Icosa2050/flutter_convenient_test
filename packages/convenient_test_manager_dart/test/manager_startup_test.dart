import 'dart:io';

import 'package:convenient_test_manager_dart/misc/setup.dart' as manager_setup;
import 'package:convenient_test_manager_dart/services/convenient_test_manager_service.dart';
import 'package:convenient_test_manager_dart/services/real_vm_service_wrapper_service.dart';
import 'package:convenient_test_manager_dart/services/vm_service_wrapper_service.dart';
import 'package:convenient_test_manager_dart/stores/worker_super_run_store.dart';
import 'package:get_it/get_it.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async {
    if (GetIt.I.isRegistered<ConvenientTestManagerService>()) {
      await GetIt.I.get<ConvenientTestManagerService>().shutdown();
    }
    await GetIt.I.reset();
  });

  test('headless setup can defer both manager and VM startup', () async {
    await manager_setup.setup(
      headlessMode: true,
      parseConfigFile: false,
      startManagerServer: false,
      autoConnectVm: false,
    );

    final manager = GetIt.I.get<ConvenientTestManagerService>();
    final vm = GetIt.I.get<VmServiceWrapperService>();

    expect(manager.boundPort, isNull);
    expect(vm, isA<RealVmServiceWrapperService>());
    expect(vm.connected, isFalse);
  });

  test(
    'serve returns the actual port and repeated starts are idempotent',
    () async {
      final manager = _createManager();

      final firstPort = await manager.serve(address: '127.0.0.1', port: 0);
      final secondPort = await manager.serve(address: '127.0.0.1', port: 0);

      expect(firstPort, greaterThan(0));
      expect(secondPort, firstPort);
      expect(manager.boundPort, firstPort);
    },
  );

  test('an awaited bind failure leaves the manager retryable', () async {
    final reservation = await ServerSocket.bind('127.0.0.1', 0);
    final port = reservation.port;
    final manager = _createManager();

    await expectLater(
      manager.serve(address: '127.0.0.1', port: port),
      throwsA(isA<SocketException>()),
    );
    expect(manager.boundPort, isNull);

    await reservation.close();
    expect(await manager.serve(address: '127.0.0.1', port: port), port);
  });

  test('shutdown releases the listener and permits restart', () async {
    final manager = _createManager();
    final port = await manager.serve(address: '127.0.0.1', port: 0);

    await manager.shutdown();
    expect(manager.boundPort, isNull);

    final reservation = await ServerSocket.bind('127.0.0.1', port);
    await reservation.close();

    expect(await manager.serve(address: '127.0.0.1', port: port), port);
  });
}

ConvenientTestManagerService _createManager() {
  GetIt.I.registerSingleton<WorkerSuperRunStore>(WorkerSuperRunStore());
  final manager = ConvenientTestManagerService();
  GetIt.I.registerSingleton<ConvenientTestManagerService>(manager);
  return manager;
}
