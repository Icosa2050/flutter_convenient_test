import 'dart:convert';

/// A decoded record from Flutter's newline-delimited `--machine` protocol.
sealed class FlutterMachineRecord {
  const FlutterMachineRecord();
}

final class FlutterMachineEvent extends FlutterMachineRecord {
  const FlutterMachineEvent({required this.name, required this.params});

  final String name;
  final Map<String, Object?> params;
}

final class FlutterMachineResponse extends FlutterMachineRecord {
  const FlutterMachineResponse({
    required this.id,
    this.result,
    this.error,
    this.trace,
  });

  final Object id;
  final Object? result;
  final Object? error;
  final String? trace;
}

final class FlutterMachineLog extends FlutterMachineRecord {
  const FlutterMachineLog({
    required this.text,
    required this.malformedProtocol,
    required this.truncated,
  });

  final String text;
  final bool malformedProtocol;
  final bool truncated;
}

/// Decoder and encoder for the stdio protocol used by `flutter run --machine`.
final class FlutterMachineProtocol {
  FlutterMachineProtocol({this.maxRecordCharacters = 16 * 1024}) {
    if (maxRecordCharacters <= 0) {
      throw ArgumentError.value(
        maxRecordCharacters,
        'maxRecordCharacters',
        'must be positive',
      );
    }
  }

  final int maxRecordCharacters;

  Stream<FlutterMachineRecord> decode(Stream<List<int>> bytes) async* {
    final lines = bytes
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (line.isEmpty) {
        continue;
      }
      for (final record in _decodeLine(line)) {
        yield record;
      }
    }
  }

  Iterable<FlutterMachineRecord> _decodeLine(String line) sync* {
    final truncated = line.length > maxRecordCharacters;
    final bounded = truncated ? line.substring(0, maxRecordCharacters) : line;
    if (truncated) {
      yield FlutterMachineLog(
        text: bounded,
        malformedProtocol: line.startsWith('['),
        truncated: true,
      );
      return;
    }

    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      yield FlutterMachineLog(
        text: bounded,
        malformedProtocol: line.startsWith('['),
        truncated: false,
      );
      return;
    }

    if (decoded is! List<Object?> || decoded.isEmpty) {
      yield FlutterMachineLog(
        text: bounded,
        malformedProtocol: true,
        truncated: false,
      );
      return;
    }

    for (final item in decoded) {
      final record = _decodeItem(item);
      if (record == null) {
        yield FlutterMachineLog(
          text: bounded,
          malformedProtocol: true,
          truncated: false,
        );
        return;
      }
      yield record;
    }
  }

  FlutterMachineRecord? _decodeItem(Object? item) {
    if (item is! Map<String, Object?>) {
      return null;
    }
    final event = item['event'];
    if (event != null) {
      if (event is! String) {
        return null;
      }
      final params = item['params'];
      if (params != null && params is! Map<String, Object?>) {
        return null;
      }
      return FlutterMachineEvent(
        name: event,
        params: params as Map<String, Object?>? ?? const <String, Object?>{},
      );
    }

    final id = item['id'];
    if (id == null ||
        (!item.containsKey('result') && !item.containsKey('error'))) {
      return null;
    }
    final trace = item['trace'];
    if (trace != null && trace is! String) {
      return null;
    }
    return FlutterMachineResponse(
      id: id,
      result: item['result'],
      error: item['error'],
      trace: trace as String?,
    );
  }

  static String encodeRequest({
    required Object id,
    required String method,
    required Map<String, Object?> params,
  }) => jsonEncode(<Object?>[
    <String, Object?>{'id': id, 'method': method, 'params': params},
  ]);
}
