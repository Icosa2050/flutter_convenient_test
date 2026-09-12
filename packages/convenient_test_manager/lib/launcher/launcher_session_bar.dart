import 'dart:async';

import 'package:convenient_test_manager/build/generated/launcher_l10n/launcher_localizations.dart';
import 'package:convenient_test_manager/launcher/flutter_worker_process.dart';
import 'package:convenient_test_manager/launcher/launcher_controller.dart';
import 'package:flutter/material.dart';

class LauncherSessionBar extends StatelessWidget {
  const LauncherSessionBar({required this.controller, super.key});

  final LauncherController controller;

  @override
  Widget build(BuildContext context) {
    final localizations = LauncherLocalizations.of(context);
    final session = controller.session;
    final shouldShow =
        session != null ||
        controller.canCancelLaunch ||
        controller.canRetryCleanup ||
        controller.ownsWorker ||
        controller.state == LauncherState.connecting ||
        controller.state == LauncherState.stopping;
    if (!shouldShow) return const SizedBox.shrink();

    final canDisconnectExternal = session?.external == true;
    final canCancelUnboundConnection =
        session == null && controller.state == LauncherState.connecting;
    final action = controller.canRetryCleanup
        ? localizations.launcherRetry
        : canDisconnectExternal
        ? localizations.launcherDisconnect
        : canCancelUnboundConnection
        ? localizations.launcherCancel
        : localizations.launcherStop;
    final actionEnabled =
        controller.state != LauncherState.stopping &&
        (controller.canStop ||
            controller.canCancelLaunch ||
            controller.canRetryCleanup ||
            canDisconnectExternal ||
            canCancelUnboundConnection);

    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            dense: true,
            leading: controller.isBusy
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    controller.state == LauncherState.failed
                        ? Icons.error_outline
                        : Icons.laptop_mac,
                  ),
            title: Text(
              controller.state == LauncherState.validating &&
                      controller.canCancelLaunch
                  ? localizations.launcherStarting
                  : launcherStateText(localizations, controller.state),
            ),
            subtitle: session == null
                ? null
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectableText(
                        localizations.launcherSessionDiagnostics(
                          session.sessionId,
                          session.managerPort,
                          session.workerUri?.toString() ??
                              launcherStateText(
                                localizations,
                                controller.state,
                              ),
                          session.reportPath,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        localizations.launcherSharedResourceWarning,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
            trailing: Semantics(
              identifier: 'launcher.stop',
              label: action,
              button: true,
              enabled: actionEnabled,
              onTap: actionEnabled ? () => unawaited(controller.stop()) : null,
              child: ExcludeSemantics(
                child: OutlinedButton(
                  onPressed: actionEnabled ? controller.stop : null,
                  child: Text(action),
                ),
              ),
            ),
          ),
          if (controller.logs.isNotEmpty)
            LauncherLogsView(logs: controller.logs),
          Divider(
            height: 1,
            thickness: 1,
            color: Theme.of(context).colorScheme.outline,
          ),
        ],
      ),
    );
  }
}

class LauncherLogsView extends StatelessWidget {
  const LauncherLogsView({required this.logs, super.key});

  final List<WorkerLogEvent> logs;

  @override
  Widget build(BuildContext context) {
    final localizations = LauncherLocalizations.of(context);
    return Semantics(
      identifier: 'launcher.logs',
      label: localizations.launcherLogs,
      child: ExpansionTile(
        dense: true,
        title: Text(localizations.launcherLogs),
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: SelectableText(
                  logs.map((event) => event.message).join('\n'),
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(fontFamily: 'RobotoMono'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String launcherStateText(
  LauncherLocalizations localizations,
  LauncherState state,
) => switch (state) {
  LauncherState.idle => localizations.launcherIdle,
  LauncherState.validating => localizations.launcherRestoringSelections,
  LauncherState.starting => localizations.launcherStarting,
  LauncherState.connecting => localizations.launcherConnecting,
  LauncherState.running => localizations.launcherRunning,
  LauncherState.stopping => localizations.launcherStopping,
  LauncherState.failed => localizations.launcherRetry,
};

String launcherDiagnosticText(
  LauncherLocalizations localizations,
  LauncherDiagnostic diagnostic,
) {
  final arguments = diagnostic.arguments;
  final details = arguments.values.isEmpty
      ? diagnostic.code.name
      : arguments.values.map((value) => value.toString()).join(', ');
  final path =
      (arguments['path'] ??
              arguments['entrypoint'] ??
              arguments['attemptedPaths'] ??
              details)
          .toString();
  final int port = _intArgument(arguments['port']);
  final int exitCode = _intArgument(arguments['exitCode']);
  final int pid = _intArgument(arguments['pid']);

  return switch (diagnostic.code) {
    LauncherErrorCode.busy => localizations.launcherProcessFailure(details),
    LauncherErrorCode.incompleteSelection =>
      localizations.launcherProjectRequired,
    LauncherErrorCode.invalidProject => localizations.launcherInvalidProject(
      path,
    ),
    LauncherErrorCode.invalidEntrypoint =>
      localizations.launcherInvalidEntrypoint(path),
    LauncherErrorCode.invalidSdk => localizations.launcherInvalidSdk(path),
    LauncherErrorCode.reservedDefine => localizations.launcherReservedDefine(
      (arguments['key'] ?? details).toString(),
    ),
    LauncherErrorCode.deviceDiscoveryFailure ||
    LauncherErrorCode.noDevices => localizations.launcherNoDevicesFound(path),
    LauncherErrorCode.noEntrypoints => localizations.launcherNoTestsFound(path),
    LauncherErrorCode.restoreFailure => localizations.launcherRestoreFailure(
      details,
    ),
    LauncherErrorCode.saveFailure => localizations.launcherSaveFailure(details),
    LauncherErrorCode.reportLoadFailure =>
      localizations.launcherReportLoadFailure(details),
    LauncherErrorCode.bindFailure || LauncherErrorCode.connectionFailure =>
      localizations.launcherConnectionFailure(details),
    LauncherErrorCode.portConflict => localizations.launcherPortConflict(port),
    LauncherErrorCode.invalidManagerPort =>
      localizations.launcherInvalidManagerPort(port),
    LauncherErrorCode.invalidWorkerEndpoint =>
      localizations.launcherInvalidWorkerEndpoint(details),
    LauncherErrorCode.processStartFailure =>
      localizations.launcherProcessStartFailure(details),
    LauncherErrorCode.buildFailure => localizations.launcherBuildFailure(
      details,
    ),
    LauncherErrorCode.processExited => localizations.launcherProcessExited(
      exitCode,
    ),
    LauncherErrorCode.processFailure => localizations.launcherProcessFailure(
      details,
    ),
    LauncherErrorCode.cleanupFailure when pid > 0 =>
      localizations.launcherOwnedProcessRemaining(pid, details),
    LauncherErrorCode.cleanupFailure => localizations.launcherCleanupFailure(
      details,
    ),
  };
}

int _intArgument(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}
