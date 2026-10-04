import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:codezz/core/rpc/channel_client.dart';
import 'package:codezz/core/rpc/serialization.dart';
import 'package:codezz/core/rpc/socket_protocol.dart';

Uint8List encodeMessage(Object? header, Object? body) =>
    (RpcWriter()..write(header)..write(body)).takeBytes();

void main() {
  group('serialization', () {
    test('matches @zcode/rpc wire bytes', () {
      // serialize([100, 0, "a", "b"]) + serialize(undefined)
      expect(encodeMessage([100, 0, 'a', 'b'], null),
          [4, 4, 6, 100, 6, 0, 1, 1, 0x61, 1, 1, 0x62, 0]);
      // VQL of 300 = 0xAC 0x02
      expect((RpcWriter()..write(300)).takeBytes(), [6, 0xAC, 0x02]);
      // Objects fall back to JSON.
      expect((RpcWriter()..write({'x': true})).takeBytes(),
          [5, 10, ...utf8.encode('{"x":true}')]);
    });

    test('round-trips values', () {
      final value = [
        'héllo',
        42,
        -1,
        1.5,
        {'a': [1, 2], 'b': null},
        Uint8List.fromList([1, 2, 3]),
        null,
      ];
      final r = RpcReader((RpcWriter()..write(value)).takeBytes());
      final out = r.read() as List;
      expect(out[0], 'héllo');
      expect(out[1], 42);
      expect(out[2], -1);
      expect(out[3], 1.5);
      expect(out[4], {'a': [1, 2], 'b': null});
      expect(out[5], [1, 2, 3]);
      expect(out[6], isNull);
    });

    test('restores nested Uint8Array markers', () {
      final writer = RpcWriter()
        ..write({
          'data': Uint8List.fromList([7, 8])
        });
      final out = RpcReader(writer.takeBytes()).read() as Map;
      expect(out['data'], isA<Uint8List>());
      expect(out['data'], [7, 8]);
    });
  });

  group('socket framing', () {
    test('handles split and coalesced frames', () {
      final a = SocketFrame.encode(Uint8List.fromList([1, 2, 3]));
      final b = SocketFrame.encode(Uint8List.fromList([4]));
      final joined = Uint8List.fromList([...a, ...b]);
      final reader = SocketFrameReader();
      expect(reader.accept(Uint8List.sublistView(joined, 0, 5)), isEmpty);
      expect(reader.accept(Uint8List.sublistView(joined, 5, 17)).map((e) => e.toList()), [
        [1, 2, 3]
      ]);
      expect(reader.accept(Uint8List.sublistView(joined, 17)).map((e) => e.toList()), [
        [4]
      ]);
    });
  });

  group('ChannelClient', () {
    late List<Uint8List> sent;
    late ChannelClient client;

    setUp(() {
      sent = [];
      client = ChannelClient(sent.add);
    });

    List<Object?> decodeSent(int i) {
      final r = RpcReader(sent[i]);
      return [r.read(), r.read()];
    }

    test('waits for Initialize, then resolves calls', () async {
      final future = client.call<Object?>('zcode-task', 'listTasks', [
        {'workspacePath': '/w'}
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(sent, isEmpty);
      client.acceptMessage(encodeMessage([200], null));
      await Future<void>.delayed(Duration.zero);
      expect(decodeSent(0), [
        [100, 0, 'zcode-task', 'listTasks'],
        [
          {'workspacePath': '/w'}
        ]
      ]);
      client.acceptMessage(encodeMessage([201, 0], ['ok']));
      expect(await future, ['ok']);
    });

    test('maps PromiseError to RpcError with code', () async {
      client.acceptMessage(encodeMessage([200], null));
      final future = client.call<Object?>('zcode-agent', 'x');
      client.acceptMessage(encodeMessage([202, 0], {
        'message': 'runtime down',
        'name': 'Error',
        'code': 'ZCODE_AGENT_RUNTIME_UNAVAILABLE',
      }));
      await expectLater(
          future,
          throwsA(isA<RpcError>()
              .having((e) => e.code, 'code', 'ZCODE_AGENT_RUNTIME_UNAVAILABLE')));
    });

    test('events listen and dispose', () async {
      client.acceptMessage(encodeMessage([200], null));
      final events = <Object?>[];
      final sub = client.listen('zcode-agent', 'onDynamicSessionsIndexFrame', {'workspacePath': '/w'})
          .listen(events.add);
      await Future<void>.delayed(Duration.zero);
      expect(decodeSent(0)[0], [102, 0, 'zcode-agent', 'onDynamicSessionsIndexFrame']);
      client.acceptMessage(encodeMessage([204, 0], {'n': 1}));
      await Future<void>.delayed(Duration.zero);
      expect(events, [
        {'n': 1}
      ]);
      await sub.cancel();
      expect(decodeSent(1)[0], [103, 0]);
    });

    test('dispose fails pending calls', () async {
      client.acceptMessage(encodeMessage([200], null));
      final future = client.call<Object?>('a', 'b');
      client.dispose(const ConnectionClosedError('gone'));
      await expectLater(future, throwsA(isA<ConnectionClosedError>()));
    });

    test('timeouts cancel the request', () async {
      client.acceptMessage(encodeMessage([200], null));
      final future = client.call<Object?>('a', 'b', const [], const Duration(milliseconds: 10));
      await expectLater(future, throwsA(isA<TimeoutException>()));
      expect(decodeSent(1)[0], [101, 0]);
    });
  });
}
