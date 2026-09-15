import 'dart:async';

import 'package:convenient_test_manager/build/generated/launcher_l10n/launcher_localizations.dart';
import 'package:convenient_test_manager/launcher/flutter_worker_process.dart';
import 'package:convenient_test_manager/launcher/launcher_controller.dart';
import 'package:convenient_test_manager/launcher/launcher_session_bar.dart';
import 'package:convenient_test_manager/services/misc_flutter_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

typedef LauncherPathChooser = Future<String?> Function();
typedef LauncherReportReader =
    Future<void> Function(String path, bool Function() isCurrent);

Future<String?> pickLauncherReportPath() async {
  final result = await FilePicker.platform.pickFiles(
    allowMultiple: false,
    type: FileType.any,
  );
  return result?.files.single.path;
}

Future<void> readLauncherReport(String path, bool Function() isCurrent) async {
  await GetIt.I.get<MiscFlutterService>().pickFileAndReadReportWithAuthority(
    pathOverride: path,
    isCurrent: isCurrent,
  );
}

class LauncherPanel extends StatefulWidget {
  const LauncherPanel({
    required this.controller,
    this.chooseProjectDirectory,
    this.chooseFlutterExecutable,
    this.chooseReportPath,
    this.readReport,
    super.key,
  });

  final LauncherController controller;
  final LauncherPathChooser? chooseProjectDirectory;
  final LauncherPathChooser? chooseFlutterExecutable;
  final LauncherPathChooser? chooseReportPath;
  final LauncherReportReader? readReport;

  @override
  State<LauncherPanel> createState() => _LauncherPanelState();
}

class _LauncherPanelState extends State<LauncherPanel> {
  late final TextEditingController _definesController;
  late final TextEditingController _managerPortController;
  late final TextEditingController _workerUriController;
  late final FocusNode _definesFocusNode;
  Map<String, String> _lastDefines = const {};
  bool _definesInvalid = false;
  String? _reservedDefine;
  bool _pickerPending = false;
  bool _selectionCancelled = false;
  bool _pickerFailed = false;

  @override
  void initState() {
    super.initState();
    _lastDefines = widget.controller.selection.dartDefines;
    _definesController = TextEditingController(
      text: _formatDefines(_lastDefines),
    );
    _managerPortController = TextEditingController(text: '3579');
    _workerUriController = TextEditingController(
      text: 'ws://127.0.0.1:9753/ws',
    );
    _definesFocusNode = FocusNode();
    widget.controller.addListener(_handleControllerChanged);
  }

  @override
  void didUpdateWidget(covariant LauncherPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleControllerChanged);
      widget.controller.addListener(_handleControllerChanged);
      _syncDefines();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    _definesController.dispose();
    _managerPortController.dispose();
    _workerUriController.dispose();
    _definesFocusNode.dispose();
    super.dispose();
  }

  void _handleControllerChanged() {
    _syncDefines();
    if (mounted) setState(() {});
  }

  void _syncDefines() {
    final current = widget.controller.selection.dartDefines;
    if (!_definesFocusNode.hasFocus && !mapEquals(current, _lastDefines)) {
      _definesController.text = _formatDefines(current);
      _lastDefines = current;
      _definesInvalid = false;
      _reservedDefine = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final localizations = LauncherLocalizations.of(context);
    final selection = widget.controller.selection;
    final mutationsEnabled =
        !widget.controller.isBusy &&
        !widget.controller.isLoadingReport &&
        widget.controller.session == null &&
        !widget.controller.ownsWorker;

    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: EdgeInsets.symmetric(
          horizontal: constraints.maxWidth < 600 ? 16 : 24,
          vertical: 20,
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  localizations.launcherTitle,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                if (selection.restoring || selection.saving) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      if (selection.restoring)
                        const Padding(
                          padding: EdgeInsets.only(right: 12),
                          child: SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      Expanded(
                        child: Text(
                          selection.restoring
                              ? localizations.launcherRestoringSelections
                              : localizations.launcherSavingSelections,
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 20),
                _pathChooser(
                  context: context,
                  identifier: 'launcher.project.choose',
                  label: localizations.launcherProjectLabel,
                  actionLabel: localizations.launcherProjectChoose,
                  value: selection.projectDirectory,
                  enabled: mutationsEnabled && !_pickerPending,
                  onPressed: _chooseProject,
                ),
                const SizedBox(height: 16),
                Semantics(
                  identifier: 'launcher.test.select',
                  label: localizations.launcherEntrypointLabel,
                  child: DropdownButtonFormField<String>(
                    key: ValueKey(selection.entrypoint),
                    initialValue: selection.entrypoint,
                    isExpanded: true,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      labelText: localizations.launcherEntrypointLabel,
                    ),
                    hint: Text(localizations.launcherEntrypointSelect),
                    items: selection.entrypoints
                        .map(
                          (entrypoint) => DropdownMenuItem(
                            value: entrypoint,
                            child: Text(
                              entrypoint,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: mutationsEnabled
                        ? widget.controller.chooseEntrypoint
                        : null,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Semantics(
                        identifier: 'launcher.device.select',
                        label: localizations.launcherDeviceLabel,
                        child: DropdownButtonFormField<String>(
                          key: ValueKey(selection.deviceId),
                          initialValue: selection.deviceId,
                          isExpanded: true,
                          decoration: InputDecoration(
                            border: const OutlineInputBorder(),
                            labelText: localizations.launcherDeviceLabel,
                          ),
                          hint: Text(localizations.launcherDeviceSelect),
                          items: selection.devices
                              .map(
                                (device) => DropdownMenuItem(
                                  value: device.id,
                                  child: Text(
                                    device.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: mutationsEnabled
                              ? widget.controller.chooseDevice
                              : null,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Semantics(
                      label: localizations.launcherRefreshDevices,
                      button: true,
                      enabled:
                          mutationsEnabled &&
                          selection.flutterExecutable != null,
                      child: IconButton(
                        tooltip: localizations.launcherRefreshDevices,
                        onPressed:
                            mutationsEnabled &&
                                selection.flutterExecutable != null
                            ? widget.controller.refreshDevices
                            : null,
                        icon: selection.refreshingDevices
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.refresh),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(localizations.launcherAdvancedSettings),
                  children: [
                    _pathChooser(
                      context: context,
                      identifier: 'launcher.sdk.choose',
                      label: localizations.launcherSdkLabel,
                      actionLabel: localizations.launcherSdkChoose,
                      value: selection.flutterExecutable,
                      enabled:
                          mutationsEnabled &&
                          !_pickerPending &&
                          selection.projectDirectory != null,
                      onPressed: _chooseSdk,
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _definesController,
                      focusNode: _definesFocusNode,
                      enabled: widget.controller.canEditDartDefines,
                      minLines: 3,
                      maxLines: 7,
                      keyboardType: TextInputType.multiline,
                      decoration: InputDecoration(
                        border: const OutlineInputBorder(),
                        labelText: localizations.launcherDartDefinesLabel,
                        hintText: localizations.launcherDartDefinesHint,
                        errorText: _reservedDefine != null
                            ? localizations.launcherReservedDefine(
                                _reservedDefine!,
                              )
                            : _definesInvalid
                            ? localizations.launcherDartDefinesHint
                            : null,
                      ),
                      onChanged: _onDefinesChanged,
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(localizations.launcherExternalConnectionTitle),
                  subtitle: Text(localizations.launcherExternalConnectionHelp),
                  children: [
                    TextField(
                      controller: _managerPortController,
                      enabled: mutationsEnabled,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        border: const OutlineInputBorder(),
                        labelText:
                            localizations.launcherExternalManagerPortLabel,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _workerUriController,
                      enabled: mutationsEnabled,
                      keyboardType: TextInputType.url,
                      decoration: InputDecoration(
                        border: const OutlineInputBorder(),
                        labelText:
                            localizations.launcherExternalWorkerEndpointLabel,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Semantics(
                        identifier: 'launcher.connect_external',
                        label: localizations.launcherConnectExisting,
                        button: true,
                        enabled: mutationsEnabled,
                        onTap: mutationsEnabled
                            ? () => unawaited(_connectExternal())
                            : null,
                        child: ExcludeSemantics(
                          child: OutlinedButton.icon(
                            onPressed: mutationsEnabled
                                ? _connectExternal
                                : null,
                            icon: const Icon(Icons.link),
                            label: Text(localizations.launcherConnectExisting),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  localizations.launcherSharedResourceWarning,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (_selectionCancelled) ...[
                  const SizedBox(height: 12),
                  Text(localizations.launcherSelectionCancelled),
                ],
                if (_pickerFailed) ...[
                  const SizedBox(height: 12),
                  Text(localizations.launcherPickerFailure),
                ],
                if (widget.controller.error != null) ...[
                  const SizedBox(height: 12),
                  _ErrorPanel(
                    message: launcherDiagnosticText(
                      localizations,
                      widget.controller.error!,
                    ),
                    retry: widget.controller.canRetryCleanup
                        ? widget.controller.stop
                        : null,
                  ),
                ],
                if (widget.controller.logs.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  LauncherLogsView(logs: widget.controller.logs),
                ],
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      Semantics(
                        identifier: 'launcher.load_report',
                        label: widget.controller.isLoadingReport
                            ? localizations.launcherLoadingReport
                            : localizations.launcherLoadReport,
                        button: true,
                        enabled: widget.controller.canLoadReport,
                        onTap: widget.controller.canLoadReport
                            ? () => unawaited(_loadReport())
                            : null,
                        child: ExcludeSemantics(
                          child: OutlinedButton.icon(
                            onPressed: widget.controller.canLoadReport
                                ? _loadReport
                                : null,
                            icon: widget.controller.isLoadingReport
                                ? const SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.upload_file),
                            label: Text(
                              widget.controller.isLoadingReport
                                  ? localizations.launcherLoadingReport
                                  : localizations.launcherLoadReport,
                            ),
                          ),
                        ),
                      ),
                      Semantics(
                        identifier: 'launcher.start',
                        label: localizations.launcherStart,
                        button: true,
                        enabled: widget.controller.canStart && !_definesInvalid,
                        onTap: widget.controller.canStart && !_definesInvalid
                            ? () => unawaited(widget.controller.start())
                            : null,
                        child: ExcludeSemantics(
                          child: FilledButton.icon(
                            onPressed:
                                widget.controller.canStart && !_definesInvalid
                                ? widget.controller.start
                                : null,
                            icon: const Icon(Icons.play_arrow),
                            label: Text(
                              widget.controller.state == LauncherState.failed
                                  ? localizations.launcherRetry
                                  : localizations.launcherStart,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _pathChooser({
    required BuildContext context,
    required String identifier,
    required String label,
    required String actionLabel,
    required String? value,
    required bool enabled,
    required Future<void> Function() onPressed,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final field = InputDecorator(
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            labelText: label,
          ),
          child: Text(
            value ?? actionLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        );
        final button = Semantics(
          identifier: identifier,
          label: actionLabel,
          button: true,
          enabled: enabled,
          onTap: enabled ? () => unawaited(onPressed()) : null,
          child: ExcludeSemantics(
            child: OutlinedButton(
              onPressed: enabled ? onPressed : null,
              child: Text(actionLabel),
            ),
          ),
        );
        if (constraints.maxWidth < 520) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [field, const SizedBox(height: 8), button],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: field),
            const SizedBox(width: 12),
            button,
          ],
        );
      },
    );
  }

  Future<void> _chooseProject() async {
    await _choosePath(
      chooser:
          widget.chooseProjectDirectory ??
          () => FilePicker.platform.getDirectoryPath(),
      onSelected: widget.controller.chooseProject,
    );
  }

  Future<void> _chooseSdk() async {
    await _choosePath(
      chooser: widget.chooseFlutterExecutable ?? _pickSdkFile,
      onSelected: widget.controller.chooseFlutterExecutable,
    );
  }

  Future<void> _loadReport() => widget.controller.loadReport(
    choosePath: widget.chooseReportPath ?? pickLauncherReportPath,
    readReport: widget.readReport ?? readLauncherReport,
  );

  Future<void> _choosePath({
    required LauncherPathChooser chooser,
    required Future<void> Function(String path) onSelected,
  }) async {
    if (_pickerPending) return;
    setState(() {
      _pickerPending = true;
      _selectionCancelled = false;
      _pickerFailed = false;
    });

    String? path;
    try {
      path = await chooser();
    } on Exception {
      if (!mounted) return;
      setState(() {
        _pickerPending = false;
        _pickerFailed = true;
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      _pickerPending = false;
      _selectionCancelled = path == null;
    });
    if (path != null) await onSelected(path);
  }

  Future<String?> _pickSdkFile() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.any,
    );
    return result?.files.single.path;
  }

  void _onDefinesChanged(String value) {
    final parsed = <String, String>{};
    String? reserved;
    var invalid = false;
    for (final line in value.split('\n')) {
      if (line.trim().isEmpty) continue;
      final separator = line.indexOf('=');
      if (separator <= 0) {
        invalid = true;
        break;
      }
      final key = line.substring(0, separator).trim();
      if (key.isEmpty) {
        invalid = true;
        break;
      }
      if (FlutterWorkerProcess.reservedDartDefineKeys.contains(key)) {
        reserved = key;
        break;
      }
      parsed[key] = line.substring(separator + 1);
    }
    setState(() {
      _definesInvalid = invalid || reserved != null;
      _reservedDefine = reserved;
    });
    if (!_definesInvalid) {
      _lastDefines = Map<String, String>.unmodifiable(parsed);
      unawaited(widget.controller.setDartDefines(parsed));
    }
  }

  Future<void> _connectExternal() async {
    final port = int.tryParse(_managerPortController.text.trim()) ?? 0;
    final uri = Uri.tryParse(_workerUriController.text.trim()) ?? Uri();
    await widget.controller.connectExternal(managerPort: port, workerUri: uri);
  }

  static String _formatDefines(Map<String, String> defines) =>
      defines.entries.map((entry) => '${entry.key}=${entry.value}').join('\n');
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message, this.retry});

  final String message;
  final Future<void> Function()? retry;

  @override
  Widget build(BuildContext context) {
    final localizations = LauncherLocalizations.of(context);
    return Material(
      color: Theme.of(context).colorScheme.errorContainer,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.error_outline,
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 12),
            Expanded(child: SelectableText(message)),
            if (retry != null) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: retry,
                child: Text(localizations.launcherRetry),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
