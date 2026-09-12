import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:convenient_test_manager/launcher/flutter_worker_process.dart';
import 'package:convenient_test_manager/launcher/launcher_controller.dart';
import 'package:convenient_test_manager/launcher/launcher_preferences.dart';
import 'package:convenient_test_manager/launcher/launcher_session_services.dart';
import 'package:convenient_test_manager/launcher/project_discovery.dart';
import 'package:convenient_test_manager/misc/setup.dart' as manager_setup;
import 'package:convenient_test_manager_dart/services/misc_dart_service.dart';
import 'package:convenient_test_manager_dart/stores/suite_info_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:path/path.dart' as p;

const _platform = String.fromEnvironment('LAUNCHER_NATIVE_PLATFORM');
const _deviceId = String.fromEnvironment('LAUNCHER_NATIVE_DEVICE_ID');
const _fixtureRoot = String.fromEnvironment('LAUNCHER_NATIVE_FIXTURE_ROOT');
const _flutterExecutable = String.fromEnvironment('LAUNCHER_NATIVE_FLUTTER');
const _reportRoot = String.fromEnvironment('LAUNCHER_NATIVE_REPORT_ROOT');

void main() {
  testWidgets(
    'production launcher completes a real $_platform convenient-test run',
    (tester) async {
      await tester.runAsync(() async {
        _validateInputs();
        await Directory(_reportRoot).create(recursive: true);

        await manager_setup.setup(
          startManagerServer: false,
          autoConnectVm: false,
          initializeLauncher: false,
          parseConfigFile: false,
          initVLC: false,
        );

        final sessionServices = GetItLauncherSessionServices();
        final controller = LauncherController(
          discovery: ProjectDiscovery(
            deviceDiscoveryTimeout: const Duration(minutes: 1),
          ),
          preferences: LauncherPreferences(
            filePath: p.join(_reportRoot, 'launcher-preferences.json'),
          ),
          process: FlutterLauncherWorkerProcess(FlutterWorkerProcess()),
          sessionServices: sessionServices,
          reportRootDirectory: _reportRoot,
          readinessTimeout: const Duration(minutes: 2),
        );

        LauncherSessionSnapshot? activeSession;
        Map<String, int>? finalCounts;
        List<String> reportFiles = const <String>[];
        int? ownedProcessGroup;
        Map<String, Object?>? stopRelease;

        try {
          _stage('discovering project, Flutter SDK, and devices');
          await controller
              .chooseProject(_fixtureRoot)
              .timeout(const Duration(minutes: 2));
          _requireNoControllerError(controller, 'chooseProject');

          await controller
              .chooseFlutterExecutable(_flutterExecutable)
              .timeout(const Duration(minutes: 2));
          _requireNoControllerError(controller, 'chooseFlutterExecutable');

          await controller.chooseEntrypoint(
            'integration_test/launcher_smoke_test.dart',
          );
          await controller.chooseDevice(_deviceId);
          expect(
            controller.canStart,
            isTrue,
            reason: _controllerSummary(controller),
          );

          _stage('starting production LauncherController session');
          await controller.start().timeout(const Duration(minutes: 8));
          _requireNoControllerError(controller, 'start');
          expect(controller.state, LauncherState.running);

          activeSession = controller.session;
          expect(activeSession, isNotNull);
          expect(activeSession!.external, isFalse);
          expect(activeSession.managerPort, isNot(anyOf(3579, 9753)));
          expect(activeSession.managerPort, inInclusiveRange(1, 65535));
          expect(activeSession.workerUri, isNotNull);
          _expectAuthenticatedLoopback(activeSession.workerUri!);
          ownedProcessGroup = activeSession.ownedPid;
          expect(ownedProcessGroup, isNotNull);

          _stage('requesting the real convenient-test run');
          GetIt.I.get<MiscDartService>().hotRestartAndRunTests(
            filterNameRegex: '^launcher native smoke',
          );

          finalCounts = await _waitForSuccessfulSuite(
            controller,
            timeout: const Duration(minutes: 5),
          );
          reportFiles = await _waitForReports(
            activeSession.reportPath,
            timeout: const Duration(seconds: 30),
          );

          expect(finalCounts[SimplifiedStateEnum.pending.name], 0);
          expect(finalCounts[SimplifiedStateEnum.running.name], 0);
          expect(
            finalCounts[SimplifiedStateEnum.completeFailureOrError.name],
            0,
          );
          final successCount =
              finalCounts[SimplifiedStateEnum.completeSuccess.name]! +
              finalCounts[SimplifiedStateEnum.completeSuccessButFlaky.name]!;
          expect(successCount, greaterThanOrEqualTo(1));

          _stage('stopping the owned worker and manager listener');
          await controller.stop().timeout(const Duration(seconds: 30));
          final groupMembers = await _processGroupMembers(ownedProcessGroup!);
          final managerPortClosed = await _portIsClosed(
            activeSession.managerPort,
          );
          final workerPortClosed = await _portIsClosed(
            activeSession.workerUri!.port,
          );
          stopRelease = <String, Object?>{
            'controllerState': controller.state.name,
            'ownsWorker': controller.ownsWorker,
            'sessionCleared': controller.session == null,
            'boundPort': sessionServices.boundPort,
            'connected': sessionServices.connected,
            'managerPortClosed': managerPortClosed,
            'workerPortClosed': workerPortClosed,
            'processGroupMembers': groupMembers,
          };
          expect(controller.state, LauncherState.idle);
          expect(controller.ownsWorker, isFalse);
          expect(controller.session, isNull);
          expect(sessionServices.boundPort, isNull);
          expect(sessionServices.connected, isFalse);
          expect(managerPortClosed, isTrue);
          expect(workerPortClosed, isTrue);
          expect(groupMembers, isEmpty);

          final result = <String, Object?>{
            'platform': _platform,
            'deviceId': _deviceId,
            'sessionId': activeSession.sessionId,
            'managerPort': activeSession.managerPort,
            'workerUri': activeSession.workerUri.toString(),
            'ownedProcessGroup': ownedProcessGroup,
            'reportPath': activeSession.reportPath,
            'reportFiles': reportFiles,
            'suiteCounts': finalCounts,
            'equivalentExitCode': 0,
            'stopRelease': stopRelease,
          };
          // The checked-in zsh runner consumes this single structured line.
          stdout.writeln('NATIVE_RESULT_JSON=${jsonEncode(result)}');
        } finally {
          if (controller.session != null ||
              controller.ownsWorker ||
              sessionServices.boundPort != null) {
            await controller.stop().timeout(const Duration(seconds: 30));
          }
          controller.dispose();
        }
      });
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}

void _validateInputs() {
  final values = <String, String>{
    'LAUNCHER_NATIVE_PLATFORM': _platform,
    'LAUNCHER_NATIVE_DEVICE_ID': _deviceId,
    'LAUNCHER_NATIVE_FIXTURE_ROOT': _fixtureRoot,
    'LAUNCHER_NATIVE_FLUTTER': _flutterExecutable,
    'LAUNCHER_NATIVE_REPORT_ROOT': _reportRoot,
  };
  for (final entry in values.entries) {
    if (entry.value.isEmpty) {
      throw StateError('Missing --dart-define=${entry.key}=...');
    }
  }
  if (_platform != 'macos' && _platform != 'ios') {
    throw StateError('Unsupported native platform: $_platform');
  }
  if (!File(_flutterExecutable).existsSync()) {
    throw StateError('Flutter executable does not exist: $_flutterExecutable');
  }
}

Future<Map<String, int>> _waitForSuccessfulSuite(
  LauncherController controller, {
  required Duration timeout,
}) async {
  final store = GetIt.I.get<SuiteInfoStore>();
  final stopwatch = Stopwatch()..start();
  Map<String, int>? latest;
  while (stopwatch.elapsed < timeout) {
    _requireNoControllerError(controller, 'suite execution');
    final suiteInfo = store.suiteInfo;
    if (suiteInfo != null) {
      final counts = store.calcStateCountMap(suiteInfo.rootGroup);
      latest = <String, int>{
        for (final state in SimplifiedStateEnum.values)
          state.name: counts[state],
      };
      final settled =
          latest[SimplifiedStateEnum.pending.name] == 0 &&
          latest[SimplifiedStateEnum.running.name] == 0;
      final completed = SimplifiedStateEnum.values
          .where(
            (state) =>
                state != SimplifiedStateEnum.pending &&
                state != SimplifiedStateEnum.running,
          )
          .fold<int>(0, (sum, state) => sum + latest![state.name]!);
      if (settled && completed > 0) return latest;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw TimeoutException(
    'suite did not settle; latest=$latest; ${_controllerSummary(controller)}',
    timeout,
  );
}

Future<List<String>> _waitForReports(
  String reportPath, {
  required Duration timeout,
}) async {
  final stopwatch = Stopwatch()..start();
  while (stopwatch.elapsed < timeout) {
    final files = await _nonEmptyReportFiles(reportPath);
    if (files.isNotEmpty) return files;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw TimeoutException('no non-empty report under $reportPath', timeout);
}

Future<List<String>> _nonEmptyReportFiles(String root) async {
  final directory = Directory(root);
  if (!await directory.exists()) return const <String>[];
  final files = <String>[];
  await for (final entity in directory.list(recursive: true)) {
    if (entity is File &&
        p.basename(entity.path) == 'report.bin' &&
        await entity.length() > 0) {
      files.add(entity.path);
    }
  }
  files.sort();
  return files;
}

void _expectAuthenticatedLoopback(Uri uri) {
  expect(uri.scheme, anyOf('ws', 'wss'));
  expect(uri.host, anyOf('127.0.0.1', 'localhost', '::1'));
  expect(uri.port, isNot(anyOf(3579, 9753)));
  expect(uri.port, inInclusiveRange(1, 65535));
  final segments = uri.pathSegments.where((segment) => segment.isNotEmpty);
  expect(
    segments.length,
    greaterThanOrEqualTo(2),
    reason: 'Flutter service authentication token must be preserved: $uri',
  );
  expect(segments.last, 'ws');
}

Future<bool> _portIsClosed(int port) async {
  Socket? socket;
  try {
    socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: const Duration(seconds: 1),
    );
    return false;
  } on SocketException {
    return true;
  } finally {
    socket?.destroy();
  }
}

Future<List<String>> _processGroupMembers(int processGroup) async {
  final result = await Process.run('/bin/ps', const <String>[
    '-axo',
    'pid=,ppid=,pgid=,command=',
  ]);
  if (result.exitCode != 0) {
    throw StateError('ps failed: ${result.stderr}');
  }
  return (result.stdout as String).split('\n').where((line) {
    final fields = line.trim().split(RegExp(r'\s+'));
    return fields.length >= 4 && fields[2] == '$processGroup';
  }).toList();
}

void _requireNoControllerError(LauncherController controller, String stage) {
  if (controller.error != null || controller.state == LauncherState.failed) {
    throw StateError('$stage failed: ${_controllerSummary(controller)}');
  }
}

String _controllerSummary(LauncherController controller) =>
    'state=${controller.state.name} error=${controller.error?.code.name} '
    'arguments=${controller.error?.arguments} '
    'logs=${controller.logs.map((event) => event.message).toList()}';

void _stage(String message) {
  stdout.writeln('NATIVE_STAGE platform=$_platform message=$message');
}
