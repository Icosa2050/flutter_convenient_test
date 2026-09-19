import 'package:convenient_test_manager/build/generated/launcher_l10n/launcher_localizations.dart';
import 'package:convenient_test_manager/launcher/launcher_controller.dart';
import 'package:flutter/material.dart';

/// Keeps picker state local; the controller owns the replacement lifecycle.
class SwitchTestFileButton extends StatefulWidget {
  const SwitchTestFileButton({
    required this.controller,
    this.isTestRunning,
    super.key,
  });

  final LauncherController controller;
  final bool Function()? isTestRunning;

  @override
  State<SwitchTestFileButton> createState() => _SwitchTestFileButtonState();
}

class _SwitchTestFileButtonState extends State<SwitchTestFileButton> {
  bool _choosing = false;

  Future<void> _choose() async {
    final controller = widget.controller;
    final sessionId = controller.session?.sessionId;
    final strings = LauncherLocalizations.of(context);
    setState(() => _choosing = true);
    bool current() =>
        mounted &&
        identical(controller, widget.controller) &&
        controller.session?.sessionId == sessionId &&
        controller.canSwitchEntrypoint;
    try {
      final target = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(strings.launcherSwitchTestTitle),
          content: SizedBox(
            width: 620,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(strings.launcherSwitchTestHint),
                const SizedBox(height: 12),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final path in controller.selection.entrypoints)
                        ListTile(
                          enabled: path != controller.selection.entrypoint,
                          title: Text(path),
                          onTap: () => Navigator.pop(context, path),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(strings.launcherCancel),
            ),
          ],
        ),
      );
      if (target == null || !current()) return;
      await controller.switchEntrypoint(
        target,
        confirmInterruption: () async {
          if (!mounted) return false;
          if (widget.isTestRunning?.call() != true) return true;
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(strings.launcherSwitchTestInterruptTitle),
              content: Text(
                '${strings.launcherSwitchTestInterrupt}\n\n'
                '${controller.selection.entrypoint}\n→ $target',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(strings.launcherCancel),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(strings.launcherSwitchTestConfirm),
                ),
              ],
            ),
          );
          return confirmed == true && mounted;
        },
      );
    } finally {
      if (mounted) setState(() => _choosing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = LauncherLocalizations.of(context).launcherSwitchTestFile;
    final enabled = !_choosing && widget.controller.canSwitchEntrypoint;
    return Semantics(
      identifier: 'launcher.switchTestFile',
      label: label,
      button: true,
      enabled: enabled,
      onTap: enabled ? _choose : null,
      child: ExcludeSemantics(
        child: OutlinedButton(
          onPressed: enabled ? _choose : null,
          child: Text(label),
        ),
      ),
    );
  }
}
