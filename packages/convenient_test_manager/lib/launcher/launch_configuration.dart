import 'dart:collection';

import 'package:path/path.dart' as p;

/// The complete user selection needed to launch one worker.
class LaunchConfiguration {
  LaunchConfiguration({
    required String projectDirectory,
    required String entrypoint,
    required String flutterExecutable,
    required this.deviceId,
    Map<String, String> dartDefines = const <String, String>{},
  }) : projectDirectory = _absolutePath(projectDirectory, 'projectDirectory'),
       entrypoint = _relativePath(entrypoint),
       flutterExecutable = _absolutePath(
         flutterExecutable,
         'flutterExecutable',
       ),
       dartDefines = UnmodifiableMapView<String, String>(
         Map<String, String>.of(dartDefines),
       ) {
    if (deviceId.isEmpty) {
      throw const FormatException('deviceId must not be empty');
    }
  }

  static const int schemaVersion = 1;

  /// Canonical absolute path. Callers should obtain this from project discovery.
  final String projectDirectory;

  /// Normalized project-relative Dart entrypoint path.
  final String entrypoint;

  /// Absolute Flutter executable path.
  final String flutterExecutable;
  final String deviceId;
  final Map<String, String> dartDefines;

  Map<String, Object> toJson() => <String, Object>{
    'schemaVersion': schemaVersion,
    'projectDirectory': projectDirectory,
    'entrypoint': entrypoint,
    'flutterExecutable': flutterExecutable,
    'deviceId': deviceId,
    'dartDefines': dartDefines,
  };

  factory LaunchConfiguration.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('configuration must be a JSON object');
    }
    final version = json['schemaVersion'];
    if (version != schemaVersion) {
      throw UnsupportedLaunchConfigurationVersion(version);
    }

    final definesJson = json['dartDefines'];
    if (definesJson is! Map<String, dynamic>) {
      throw const FormatException('dartDefines must be a JSON object');
    }
    final defines = <String, String>{};
    for (final entry in definesJson.entries) {
      final value = entry.value;
      if (value is! String) {
        throw const FormatException('dartDefines values must be strings');
      }
      defines[entry.key] = value;
    }

    return LaunchConfiguration(
      projectDirectory: _stringField(json, 'projectDirectory'),
      entrypoint: _stringField(json, 'entrypoint'),
      flutterExecutable: _stringField(json, 'flutterExecutable'),
      deviceId: _stringField(json, 'deviceId'),
      dartDefines: defines,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LaunchConfiguration &&
          projectDirectory == other.projectDirectory &&
          entrypoint == other.entrypoint &&
          flutterExecutable == other.flutterExecutable &&
          deviceId == other.deviceId &&
          _mapsEqual(dartDefines, other.dartDefines);

  @override
  int get hashCode {
    final defineKeys = dartDefines.keys.toList()..sort();
    return Object.hash(
      projectDirectory,
      entrypoint,
      flutterExecutable,
      deviceId,
      Object.hashAll(
        defineKeys.map((key) => Object.hash(key, dartDefines[key])),
      ),
    );
  }
}

class UnsupportedLaunchConfigurationVersion implements FormatException {
  const UnsupportedLaunchConfigurationVersion(this.version);

  final Object? version;

  @override
  String get message => 'unsupported launch configuration version: $version';

  @override
  int? get offset => null;

  @override
  Object? get source => version;

  @override
  String toString() => message;
}

String _absolutePath(String value, String fieldName) {
  if (value.isEmpty || !p.isAbsolute(value)) {
    throw FormatException('$fieldName must be an absolute path');
  }
  return p.normalize(value);
}

String _relativePath(String value) {
  if (value.isEmpty || p.isAbsolute(value)) {
    throw const FormatException('entrypoint must be a relative path');
  }
  final normalized = p.normalize(value);
  if (p.split(normalized).first == '..') {
    throw const FormatException('entrypoint must stay within the project');
  }
  return normalized;
}

String _stringField(Map<String, dynamic> json, String name) {
  final value = json[name];
  if (value is! String) {
    throw FormatException('$name must be a string');
  }
  return value;
}

bool _mapsEqual(Map<String, String> first, Map<String, String> second) {
  if (first.length != second.length) {
    return false;
  }
  return first.entries.every((entry) => second[entry.key] == entry.value);
}
