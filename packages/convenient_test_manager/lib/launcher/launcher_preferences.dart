import 'dart:convert';
import 'dart:io';

import 'package:convenient_test_manager/launcher/launch_configuration.dart';
import 'package:path/path.dart' as p;

enum LauncherPreferencesDiagnosticCode {
  malformedJson,
  unsupportedVersion,
  invalidData,
  staleConfiguration,
  ioFailure,
}

class LauncherPreferencesDiagnostic {
  const LauncherPreferencesDiagnostic(this.code, {this.arguments = const {}});

  final LauncherPreferencesDiagnosticCode code;
  final Map<String, Object?> arguments;
}

/// Persists launcher state at a caller-supplied application-support file path.
class LauncherPreferences {
  LauncherPreferences({required String filePath})
    : filePath = p.normalize(p.absolute(filePath));

  final String filePath;

  LauncherPreferencesDiagnostic? diagnostic;

  Future<LaunchConfiguration?> load() async {
    diagnostic = null;
    final file = File(filePath);
    if (!await file.exists()) {
      return null;
    }

    late Object? json;
    try {
      json = jsonDecode(await file.readAsString());
    } on FormatException catch (error) {
      diagnostic = LauncherPreferencesDiagnostic(
        LauncherPreferencesDiagnosticCode.malformedJson,
        arguments: <String, Object?>{'error': error.message},
      );
      return null;
    } on FileSystemException catch (error) {
      diagnostic = LauncherPreferencesDiagnostic(
        LauncherPreferencesDiagnosticCode.ioFailure,
        arguments: <String, Object?>{'error': error.message},
      );
      return null;
    }

    late LaunchConfiguration configuration;
    try {
      configuration = LaunchConfiguration.fromJson(json);
    } on UnsupportedLaunchConfigurationVersion catch (error) {
      diagnostic = LauncherPreferencesDiagnostic(
        LauncherPreferencesDiagnosticCode.unsupportedVersion,
        arguments: <String, Object?>{'version': error.version},
      );
      return null;
    } on FormatException catch (error) {
      diagnostic = LauncherPreferencesDiagnostic(
        LauncherPreferencesDiagnosticCode.invalidData,
        arguments: <String, Object?>{'error': error.message},
      );
      return null;
    }

    try {
      if (!await _pathsAreCurrent(configuration)) {
        diagnostic = const LauncherPreferencesDiagnostic(
          LauncherPreferencesDiagnosticCode.staleConfiguration,
        );
        return null;
      }
    } on FileSystemException catch (error) {
      diagnostic = LauncherPreferencesDiagnostic(
        LauncherPreferencesDiagnosticCode.ioFailure,
        arguments: <String, Object?>{'error': error.message},
      );
      return null;
    }
    return configuration;
  }

  Future<void> save(LaunchConfiguration configuration) async {
    diagnostic = null;
    final destination = File(filePath);
    await destination.parent.create(recursive: true);
    final temporary = File(
      '$filePath.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await temporary.writeAsString(
        jsonEncode(configuration.toJson()),
        flush: true,
      );
      await temporary.rename(filePath);
    } finally {
      if (await temporary.exists()) {
        await temporary.delete();
      }
    }
  }

  Future<bool> _pathsAreCurrent(LaunchConfiguration configuration) async {
    final project = Directory(configuration.projectDirectory);
    if (!await project.exists() ||
        !await File(p.join(project.path, 'pubspec.yaml')).exists()) {
      return false;
    }
    final canonicalProject = await project.resolveSymbolicLinks();
    if (p.normalize(canonicalProject) != configuration.projectDirectory) {
      return false;
    }

    final entrypoint = File(
      p.join(configuration.projectDirectory, configuration.entrypoint),
    );
    if (p.extension(entrypoint.path) != '.dart' || !await entrypoint.exists()) {
      return false;
    }
    final canonicalEntrypoint = await entrypoint.resolveSymbolicLinks();
    final integrationDirectory = p.join(canonicalProject, 'integration_test');
    if (!p.isWithin(canonicalProject, canonicalEntrypoint) ||
        !p.isWithin(integrationDirectory, canonicalEntrypoint)) {
      return false;
    }

    final flutterStat = await FileStat.stat(configuration.flutterExecutable);
    return flutterStat.type == FileSystemEntityType.file &&
        (flutterStat.mode & 0x49) != 0;
  }
}
