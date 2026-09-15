import 'dart:async';
import 'dart:convert';

import 'package:convenient_test_manager/launcher/flutter_machine_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FlutterMachineProtocol', () {
    test('decodes fragmented UTF-8 and multiple machine records', () async {
      final input = StreamController<List<int>>();
      final recordsFuture = FlutterMachineProtocol()
          .decode(input.stream)
          .toList();
      final bytes = utf8.encode(
        '[{"event":"app.log","params":{"appId":"app-1","log":"Grüße"}},'
        '{"event":"app.started","params":{"appId":"app-1"}}]\n',
      );
      final splitInsideUmlaut = bytes.indexOf(0xc3) + 1;

      input.add(bytes.sublist(0, splitInsideUmlaut));
      input.add(bytes.sublist(splitInsideUmlaut, bytes.length - 1));
      input.add(bytes.sublist(bytes.length - 1));
      await input.close();

      final records = await recordsFuture;
      expect(records, hasLength(2));
      expect(records[0], isA<FlutterMachineEvent>());
      expect((records[0] as FlutterMachineEvent).params['log'], 'Grüße');
      expect((records[1] as FlutterMachineEvent).name, 'app.started');
    });

    test('preserves plain output and incomplete final lines', () async {
      final records = await FlutterMachineProtocol()
          .decode(
            Stream<List<int>>.fromIterable(<List<int>>[
              utf8.encode('Building macOS application...\nlast line'),
            ]),
          )
          .toList();

      expect(records, hasLength(2));
      expect(
        (records[0] as FlutterMachineLog).text,
        'Building macOS application...',
      );
      expect((records[1] as FlutterMachineLog).text, 'last line');
      expect(
        records.whereType<FlutterMachineLog>(),
        everyElement(
          isA<FlutterMachineLog>().having(
            (record) => record.malformedProtocol,
            'malformed',
            false,
          ),
        ),
      );
    });

    test(
      'marks malformed protocol-looking records without dropping them',
      () async {
        final records = await FlutterMachineProtocol()
            .decode(
              Stream<List<int>>.value(
                utf8.encode('[{"event":42}]\n[{broken]\n'),
              ),
            )
            .toList();

        expect(records, hasLength(2));
        expect(
          records.whereType<FlutterMachineLog>(),
          everyElement(
            isA<FlutterMachineLog>().having(
              (record) => record.malformedProtocol,
              'malformed',
              true,
            ),
          ),
        );
      },
    );

    test('decodes responses and preserves daemon errors', () async {
      final records = await FlutterMachineProtocol()
          .decode(
            Stream<List<int>>.value(
              utf8.encode(
                '[{"id":7,"error":"app not found","trace":"trace text"}]\n',
              ),
            ),
          )
          .toList();

      final response = records.single as FlutterMachineResponse;
      expect(response.id, 7);
      expect(response.error, 'app not found');
      expect(response.trace, 'trace text');
    });

    test('bounds oversized records and reports truncation', () async {
      final records = await FlutterMachineProtocol(
        maxRecordCharacters: 12,
      ).decode(Stream<List<int>>.value(utf8.encode('${'x' * 40}\n'))).toList();

      final log = records.single as FlutterMachineLog;
      expect(log.text, hasLength(12));
      expect(log.truncated, isTrue);
    });

    test('encodes requests as one machine-protocol JSON array', () {
      final encoded = FlutterMachineProtocol.encodeRequest(
        id: 3,
        method: 'app.stop',
        params: const <String, Object?>{'appId': 'app with spaces'},
      );

      expect(jsonDecode(encoded), <Object?>[
        <String, Object?>{
          'id': 3,
          'method': 'app.stop',
          'params': <String, Object?>{'appId': 'app with spaces'},
        },
      ]);
    });
  });
}
