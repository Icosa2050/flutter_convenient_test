import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:convenient_test_manager/launcher/owned_process_group.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('preserves vector arguments, cwd, stdio, and the root PID', () async {
    final directory = await Directory.systemTemp.createTemp(
      'convenient-owned-group ',
    );
    OwnedProcessGroup? group;
    try {
      group = await PosixOwnedProcessGroup.start(
        PosixOwnedProcessGroup.pythonExecutable,
        <String>[
          '-c',
          '''import os,sys; print(os.getcwd(), flush=True); print(sys.argv[1], flush=True); print(input(), flush=True)''',
          r'literal with spaces $HOME "quotes"',
        ],
        workingDirectory: directory.path,
      );
      expect(group.groupId, group.process.pid);
      expect(group.groupId, greaterThan(1));

      final output = group.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .toList();
      group.process.stdin.writeln('stdin-through-pipe');
      await group.process.stdin.flush();

      expect(await group.process.exitCode, 0);
      final resolvedDirectory = await directory.resolveSymbolicLinks();
      expect(await output, <String>[
        resolvedDirectory,
        r'literal with spaces $HOME "quotes"',
        'stdin-through-pipe',
      ]);
      expect(await group.waitForExit(const Duration(seconds: 2)), isTrue);
    } finally {
      if (group != null &&
          !await group.waitForExit(const Duration(milliseconds: 20))) {
        group.signal(ProcessSignal.sigkill);
        await group.waitForExit(const Duration(seconds: 2));
      }
      await directory.delete(recursive: true);
    }
  }, skip: !Platform.isMacOS);

  test(
    'reaps a late-spawning family after root exit without touching a sibling',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'convenient-owned-family-',
      );
      final grandchildMarker = File('${directory.path}/grandchild.pid');
      Process? sibling;
      OwnedProcessGroup? group;
      try {
        sibling = await Process.start(
          PosixOwnedProcessGroup.pythonExecutable,
          <String>['-c', 'import time; time.sleep(30)'],
        );
        group = await PosixOwnedProcessGroup.start(
          PosixOwnedProcessGroup.pythonExecutable,
          <String>['-c', _rootProgram, grandchildMarker.path],
        );
        final childPid = int.parse(
          await group.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first,
        );
        expect(childPid, greaterThan(1));
        expect(await group.process.exitCode, 0);
        expect(
          await group.waitForExit(const Duration(milliseconds: 20)),
          isFalse,
        );

        group.signal(ProcessSignal.sigterm);
        await _waitForFile(grandchildMarker);
        expect(
          int.parse(await grandchildMarker.readAsString()),
          greaterThan(1),
        );
        expect(
          await group.waitForExit(const Duration(milliseconds: 50)),
          isFalse,
        );

        group.signal(ProcessSignal.sigkill);
        expect(await group.waitForExit(const Duration(seconds: 3)), isTrue);
        await expectLater(
          sibling.exitCode.timeout(const Duration(milliseconds: 50)),
          throwsA(isA<TimeoutException>()),
        );
      } finally {
        if (group != null &&
            !await group.waitForExit(const Duration(milliseconds: 20))) {
          group.signal(ProcessSignal.sigkill);
          await group.waitForExit(const Duration(seconds: 2));
        }
        if (sibling != null) {
          sibling.kill(ProcessSignal.sigkill);
          await sibling.exitCode;
        }
        await directory.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'readiness timeout stops the root before delayed isolation can start',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'convenient-owned-delayed-isolation-',
      );
      final isolationMarker = File('${directory.path}/isolated.pid');
      Process? root;
      try {
        await expectLater(
          PosixOwnedProcessGroup.start(
            '/unused',
            const <String>[],
            startupTimeout: const Duration(milliseconds: 20),
            processStarter: _testProgramStarter(
              _delayedIsolationProgram,
              <String>[isolationMarker.path],
              onStarted: (process) => root = process,
            ),
          ),
          throwsA(isA<TimeoutException>()),
        );

        expect(root, isNotNull);
        await root!.exitCode.timeout(const Duration(seconds: 2));
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(await isolationMarker.exists(), isFalse);
      } finally {
        await _cleanupTestFamily(root, isolationMarker);
        await directory.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'readiness timeout reaps an established group and surviving descendant',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'convenient-owned-startup-family-',
      );
      final childMarker = File('${directory.path}/child.pid');
      Process? root;
      try {
        await expectLater(
          PosixOwnedProcessGroup.start(
            '/unused',
            const <String>[],
            startupTimeout: const Duration(milliseconds: 20),
            processStarter: _testProgramStarter(
              _establishedStartupFamilyProgram,
              <String>[childMarker.path],
              onStarted: (process) => root = process,
              beforeReturn: () => _waitForFile(childMarker),
            ),
          ),
          throwsA(isA<TimeoutException>()),
        );

        expect(root, isNotNull);
        expect(int.parse(await childMarker.readAsString()), greaterThan(1));
        expect(await _processGroupExists(root!.pid), isFalse);
      } finally {
        await _cleanupTestFamily(root, childMarker);
        await directory.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS,
  );
}

PosixProcessStarter _testProgramStarter(
  String program,
  List<String> arguments, {
  required void Function(Process process) onStarted,
  Future<void> Function()? beforeReturn,
}) {
  return (
    _,
    _, {
    workingDirectory,
    environment,
    includeParentEnvironment = true,
    runInShell = false,
    mode = ProcessStartMode.normal,
  }) async {
    final process = await Process.start(
      PosixOwnedProcessGroup.pythonExecutable,
      <String>['-c', program, ...arguments],
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      runInShell: runInShell,
      mode: mode,
    );
    onStarted(process);
    await beforeReturn?.call();
    return process;
  };
}

Future<bool> _processGroupExists(int groupId) async {
  final result = await Process.run(
    PosixOwnedProcessGroup.pythonExecutable,
    <String>['-c', 'import os,sys; os.kill(-int(sys.argv[1]), 0)', '$groupId'],
    runInShell: false,
  );
  return result.exitCode == 0;
}

Future<void> _cleanupTestFamily(Process? root, File isolationMarker) async {
  if (root == null) {
    return;
  }
  root.kill(ProcessSignal.sigkill);
  if (root.pid > 1 && await isolationMarker.exists()) {
    Process.killPid(-root.pid, ProcessSignal.sigkill);
  }
  try {
    await root.exitCode.timeout(const Duration(seconds: 2));
  } on TimeoutException {
    throw TimeoutException('test-owned root ${root.pid} did not exit');
  }
}

Future<void> _waitForFile(File file) async {
  final stopwatch = Stopwatch()..start();
  while (!await file.exists()) {
    if (stopwatch.elapsed > const Duration(seconds: 2)) {
      throw TimeoutException('late grandchild did not start');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

const _rootProgram = '''
import subprocess
import sys

child_program = r"""
import signal
import subprocess
import sys
import time

signal.signal(signal.SIGINT, signal.SIG_IGN)
signal.signal(signal.SIGTERM, signal.SIG_IGN)
time.sleep(0.15)
grandchild = subprocess.Popen([
    sys.executable,
    '-c',
    'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)',
])
with open(sys.argv[1], 'w', encoding='utf-8') as marker:
    marker.write(str(grandchild.pid))
time.sleep(30)
"""

child = subprocess.Popen([
    sys.executable,
    '-c',
    child_program,
    sys.argv[1],
], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print(child.pid, flush=True)
''';

const _delayedIsolationProgram = '''
import os
import subprocess
import sys
import time

time.sleep(0.2)
os.setsid()
with open(sys.argv[1], 'w', encoding='utf-8') as marker:
    marker.write(str(os.getpid()))
subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
time.sleep(30)
''';

const _establishedStartupFamilyProgram = '''
import os
import signal
import subprocess
import sys
import time

os.setsid()
child = subprocess.Popen([
    sys.executable,
    '-c',
    'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)',
])
with open(sys.argv[1], 'w', encoding='utf-8') as marker:
    marker.write(str(child.pid))
time.sleep(30)
''';
