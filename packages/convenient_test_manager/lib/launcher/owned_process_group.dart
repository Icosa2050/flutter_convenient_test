import 'dart:async';
import 'dart:io';

typedef OwnedProcessGroupStarter =
    Future<OwnedProcessGroup> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
      required bool includeParentEnvironment,
      required bool runInShell,
      required ProcessStartMode mode,
    });

typedef PosixProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
      required bool includeParentEnvironment,
      required bool runInShell,
      required ProcessStartMode mode,
    });

/// The process and lifecycle boundary for one launcher-owned command.
abstract interface class OwnedProcessGroup {
  Process get process;
  int get groupId;
  Stream<List<int>> get stdout;
  Stream<List<int>> get stderr;

  /// Sends [signal] only to this ownership boundary.
  bool signal(ProcessSignal signal);

  /// Returns true once no process remains in this ownership boundary.
  Future<bool> waitForExit(Duration timeout);
}

/// Compatibility ownership for injected process starters and non-macOS hosts.
///
/// Production macOS launches use [PosixOwnedProcessGroup] instead.
final class SingleProcessOwnership implements OwnedProcessGroup {
  SingleProcessOwnership(this.process) {
    unawaited(process.exitCode.then((_) => _exited = true));
  }

  @override
  final Process process;

  var _exited = false;

  @override
  int get groupId => process.pid;

  @override
  Stream<List<int>> get stdout => process.stdout;

  @override
  Stream<List<int>> get stderr => process.stderr;

  @override
  bool signal(ProcessSignal signal) => process.kill(signal);

  @override
  Future<bool> waitForExit(Duration timeout) async {
    if (_exited) {
      return true;
    }
    try {
      await process.exitCode.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }
}

final class OwnedProcessGroupStartException implements Exception {
  const OwnedProcessGroupStartException(
    this.message, {
    this.cleanupOwnership,
    this.cause,
  });

  final String message;
  final OwnedProcessGroup? cleanupOwnership;
  final Object? cause;

  @override
  String toString() => 'OwnedProcessGroupStartException($message)';
}

/// A macOS process group whose leader retains normal stdio and exit reporting.
///
/// Dart's detached start mode creates a new session but deliberately withholds
/// the exit code. The launcher needs both. This shim calls `setsid(2)`, writes a
/// private readiness marker, and then replaces itself with the requested
/// executable. `execv` preserves the PID, vector arguments, cwd, environment,
/// and all three pipes.
final class PosixOwnedProcessGroup implements OwnedProcessGroup {
  PosixOwnedProcessGroup._({
    required this.process,
    required Stream<List<int>> stdout,
    required bool isolationEstablished,
  }) : _stdout = stdout,
       groupId = process.pid,
       _isolationEstablished = isolationEstablished {
    unawaited(process.exitCode.then((_) => _rootExited = true));
  }

  static const pythonExecutable = '/usr/bin/python3';
  static const _readyMarker = <int>[
    30,
    99,
    111,
    110,
    118,
    101,
    110,
    105,
    101,
    110,
    116,
    95,
    116,
    101,
    115,
    116,
    95,
    111,
    119,
    110,
    101,
    100,
    95,
    112,
    114,
    111,
    99,
    101,
    115,
    115,
    95,
    103,
    114,
    111,
    117,
    112,
    95,
    118,
    49,
    10,
  ];
  static const _launchProgram = r'''
import os
import sys
os.setsid()
os.write(1, b'\x1econvenient_test_owned_process_group_v1\n')
os.execv(sys.argv[1], sys.argv[1:])
''';
  static const _probeProgram = '''
import os
import sys
try:
    os.kill(-int(sys.argv[1]), 0)
except ProcessLookupError:
    sys.exit(1)
except PermissionError:
    sys.exit(2)
''';

  static Future<OwnedProcessGroup> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
    Duration startupTimeout = const Duration(seconds: 5),
    PosixProcessStarter? processStarter,
  }) async {
    if (!Platform.isMacOS) {
      throw const OwnedProcessGroupStartException(
        'POSIX session isolation is currently supported only on macOS',
      );
    }
    if (runInShell) {
      throw const OwnedProcessGroupStartException(
        'owned process groups require vector execution',
      );
    }
    if (mode != ProcessStartMode.normal) {
      throw const OwnedProcessGroupStartException(
        'owned process groups require normal process mode',
      );
    }

    final process = await (processStarter ?? Process.start)(
      pythonExecutable,
      <String>['-c', _launchProgram, executable, ...arguments],
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      runInShell: false,
      mode: ProcessStartMode.normal,
    );
    if (process.pid <= 1) {
      process.kill(ProcessSignal.sigkill);
      throw OwnedProcessGroupStartException(
        'refusing unsafe process group id ${process.pid}',
      );
    }

    final forwardedStdout = StreamController<List<int>>();
    final ownership = PosixOwnedProcessGroup._(
      process: process,
      stdout: forwardedStdout.stream,
      isolationEstablished: false,
    );
    final ready = Completer<void>();
    final prefix = <int>[];
    late final StreamSubscription<List<int>> stdoutSubscription;
    stdoutSubscription = process.stdout.listen(
      (chunk) {
        if (ready.isCompleted) {
          forwardedStdout.add(chunk);
          return;
        }
        prefix.addAll(chunk);
        if (prefix.length < _readyMarker.length) {
          return;
        }
        final markerMatches = _readyMarker.indexed.every(
          (entry) => prefix[entry.$1] == entry.$2,
        );
        if (!markerMatches) {
          ready.completeError(
            const OwnedProcessGroupStartException(
              'session isolation readiness marker was not received',
            ),
          );
          return;
        }
        ready.complete();
        if (prefix.length > _readyMarker.length) {
          forwardedStdout.add(prefix.sublist(_readyMarker.length));
        }
        prefix.clear();
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!ready.isCompleted) {
          ready.completeError(error, stackTrace);
        } else {
          forwardedStdout.addError(error, stackTrace);
        }
      },
      onDone: () {
        if (!ready.isCompleted) {
          ready.completeError(
            const OwnedProcessGroupStartException(
              'session leader exited before isolation was established',
            ),
          );
        }
        unawaited(forwardedStdout.close());
      },
    );

    try {
      await ready.future.timeout(startupTimeout);
    } on Object catch (error, stackTrace) {
      Object? cleanupError;
      var rootSignalSent = false;
      try {
        rootSignalSent = process.kill(ProcessSignal.sigkill);
      } on Object catch (signalError) {
        cleanupError = signalError;
      }
      unawaited(
        stdoutSubscription
            .cancel()
            .whenComplete(() {
              unawaited(forwardedStdout.close());
            })
            .catchError((Object _) {
              // Process containment is verified independently below. There is
              // no useful stdout to forward after startup has already failed.
            }),
      );
      var rootExited = false;
      try {
        rootExited = await ownership._waitForRootExit(
          const Duration(seconds: 1),
        );
      } on Object catch (waitError) {
        cleanupError ??= waitError;
      }

      var groupSignalSent = false;
      try {
        groupSignalSent = ownership._signalGroup(ProcessSignal.sigkill);
      } on Object catch (signalError) {
        cleanupError ??= signalError;
      }
      var contained = false;
      try {
        contained = await ownership.waitForExit(const Duration(seconds: 1));
      } on Object catch (waitError) {
        cleanupError ??= waitError;
      }
      if (contained) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      Error.throwWithStackTrace(
        OwnedProcessGroupStartException(
          'session isolation startup failed and cleanup was not confirmed '
          '(pid=${process.pid}, rootSignalSent=$rootSignalSent, '
          'rootExited=$rootExited, groupSignalSent=$groupSignalSent'
          '${cleanupError == null ? '' : ', cleanupError=$cleanupError'})',
          cleanupOwnership: ownership,
          cause: error,
        ),
        stackTrace,
      );
    }
    ownership._isolationEstablished = true;
    return ownership;
  }

  @override
  final Process process;

  @override
  final int groupId;

  final Stream<List<int>> _stdout;
  var _isolationEstablished = false;
  var _rootExited = false;

  @override
  Stream<List<int>> get stdout => _stdout;

  @override
  Stream<List<int>> get stderr => process.stderr;

  @override
  bool signal(ProcessSignal signal) {
    var rootSignalled = false;
    if (!_isolationEstablished) {
      rootSignalled = process.kill(signal);
    }
    return _signalGroup(signal) || rootSignalled;
  }

  bool _signalGroup(ProcessSignal signal) {
    if (groupId <= 1 || groupId != process.pid) {
      throw StateError('refusing unsafe process group id $groupId');
    }
    return Process.killPid(-groupId, signal);
  }

  @override
  Future<bool> waitForExit(Duration timeout) async {
    final stopwatch = Stopwatch()..start();
    while (true) {
      if (await _waitForRootExit(Duration.zero) && !await _exists()) {
        return true;
      }
      final remaining = timeout - stopwatch.elapsed;
      if (remaining <= Duration.zero) {
        return false;
      }
      await Future<void>.delayed(
        remaining < const Duration(milliseconds: 20)
            ? remaining
            : const Duration(milliseconds: 50),
      );
    }
  }

  Future<bool> _waitForRootExit(Duration timeout) async {
    if (_rootExited) {
      return true;
    }
    try {
      await process.exitCode.timeout(timeout);
      _rootExited = true;
      return true;
    } on TimeoutException {
      return false;
    }
  }

  Future<bool> _exists() async {
    final result = await Process.run(pythonExecutable, <String>[
      '-c',
      _probeProgram,
      '$groupId',
    ], runInShell: false);
    switch (result.exitCode) {
      case 0:
        return true;
      case 1:
        return false;
      default:
        throw StateError(
          'could not inspect owned process group $groupId: '
          '${result.stderr}',
        );
    }
  }
}
