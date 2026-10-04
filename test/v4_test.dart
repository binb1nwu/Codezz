import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:codezz/core/link/device_link.dart';
import 'package:codezz/core/v4/conversation_store.dart';
import 'package:codezz/core/v4/ids.dart';
import 'package:codezz/core/v4/sessions_index_store.dart';
import 'package:codezz/core/v4/synced_topic.dart';
import 'package:codezz/core/v4/topic_router.dart';
import 'package:codezz/core/v4/wire_assembler.dart';
import 'package:codezz/core/zcode/server_info.dart';
import 'package:codezz/core/zcode/zcode_api.dart';
import 'package:codezz/ui/conversation/turn_model.dart';

class FakeContext implements WorkspaceContext {
  @override
  final WorkspaceRef workspace = const WorkspaceRef(path: '/w', label: 'w');
  @override
  late final TopicRouter router = TopicRouter(workspace);
  @override
  ZCodeApi? get api => null;
  @override
  Stream<ZCodeApi> get onApi => const Stream.empty();
  @override
  void log(String line) {}
}

Map<String, dynamic> row(int id, String kind, [Map<String, dynamic> extra = const {}]) =>
    {'rowId': id, 'turnId': 't1', 'createdAt': 0, 'createdAtSeq': id, 'kind': kind, ...extra};

Map<String, dynamic> snapshotFrame(List<Map<String, dynamic>> rows, {int seq = 5}) => {
      'topic': 'conversation/s1',
      'subscriptionId': 'sub',
      'fromSeq': 0,
      'toSeq': seq,
      'sentAt': 0,
      'payload': {
        'kind': 'snapshot',
        'snapshot': {
          'protocolVersion': 1,
          'sessionId': 's1',
          'logEpoch': 'e1',
          'seq': seq,
          'revision': 3,
          'control': {'phase': 'running', 'canStop': true},
          'rows': {'window': rows, 'totalCount': rows.length, 'firstRowId': rows.isEmpty ? null : rows.first['rowId']},
        },
      },
    };

Map<String, dynamic> deltaFrame(int from, int to, List<Map<String, dynamic>> deltas) => {
      'topic': 'conversation/s1',
      'subscriptionId': 'sub',
      'fromSeq': from,
      'toSeq': to,
      'sentAt': 0,
      'payload': {'kind': 'deltas', 'deltas': deltas},
    };

void main() {
  group('ConversationStore', () {
    test('applies snapshot and the V4 delta algebra', () async {
      final store = ConversationStore(FakeContext(), 's1');
      store.onFrame(snapshotFrame([row(1, 'turnHeader'), row(2, 'userInput', {'text': 'hi'})]), 'initial');
      expect(store.rows.length, 2);
      expect(store.running, isTrue);

      final before = store.rows[1];
      store.onFrame(
          deltaFrame(5, 8, [
            {'op': 'row.appended', 'row': row(3, 'assistantText', {'text': '', 'state': 'streaming'})},
            {'op': 'row.delta', 'rowId': 3, 'path': 'text', 'append': 'Hel'},
            {'op': 'row.delta', 'rowId': 3, 'path': 'text', 'append': 'lo'},
            {
              'op': 'state.updated',
              'patch': {
                'control': {'phase': 'completedSuccess', 'canStop': false}
              }
            },
          ]),
          'online');
      expect(store.seq, 8);
      expect(store.rows.last['text'], 'Hello');
      expect(store.running, isFalse);
      expect(identical(store.rows[1], before), isTrue, reason: 'untouched rows keep identity');

      store.onFrame(
          deltaFrame(8, 9, [
            {'op': 'row.removed', 'fromRowId': 2},
          ]),
          'online');
      expect(store.rows.map((r) => r['rowId']), [1]);
      store.dispose();
    });

    test('ignores stale frames and detects gaps', () {
      final store = ConversationStore(FakeContext(), 's1');
      store.onFrame(snapshotFrame([row(1, 'turnHeader')]), 'initial');
      store.onFrame(deltaFrame(3, 5, [
        {'op': 'row.appended', 'row': row(9, 'userInput')}
      ]), 'online');
      expect(store.rows.length, 1, reason: 'stale (toSeq <= seq)');
      store.onFrame(deltaFrame(7, 9, [
        {'op': 'row.appended', 'row': row(9, 'userInput')}
      ]), 'online');
      expect(store.rows.length, 1, reason: 'gap is not applied');
      expect(store.seq, 5);
      store.dispose();
    });
  });

  test('SessionsIndexStore upserts and removes', () {
    final store = SessionsIndexStore(FakeContext());
    store.onFrame({
      'fromSeq': 0,
      'toSeq': 1,
      'payload': {
        'kind': 'snapshot',
        'snapshot': {
          'logEpoch': 'x',
          'sessions': [
            {'sessionId': 'a', 'phase': 'running'}
          ]
        }
      }
    }, 'initial');
    store.onFrame({
      'fromSeq': 1,
      'toSeq': 2,
      'payload': {
        'kind': 'deltas',
        'deltas': [
          {'op': 'session.upserted', 'session': {'sessionId': 'b', 'phase': 'draft'}},
          {'op': 'session.removed', 'sessionId': 'a'},
        ]
      }
    }, 'online');
    expect(store.sessions.keys, ['b']);
    expect(store.status, TopicStatus.live);
    store.dispose();
  });

  group('TopicWireAssembler', () {
    Map<String, dynamic> frag(int i, int n, List<int> bytes, List<int> all, {int ordinal = 1}) => {
          'wireVersion': 3,
          'kind': 'fragment',
          'deliveryKind': 'online',
          'logicalFrameId': 'lf',
          'logicalFrameOrdinal': ordinal,
          'topic': 't',
          'subscriptionId': 's',
          'fragmentIndex': i,
          'fragmentCount': n,
          'logicalBytes': all.length,
          'checksum': {'algorithm': 'crc32', 'value': crc32Hex(all)},
          'dataBase64': base64Encode(bytes),
        };

    test('crc32 matches ZCode', () {
      expect(crc32Hex(utf8.encode('123456789')), 'cbf43926');
    });

    test('reassembles fragments out of order', () {
      final a = TopicWireAssembler();
      final all = utf8.encode(jsonEncode({'topic': 't', 'subscriptionId': 's', 'toSeq': 1}));
      final mid = all.length ~/ 2;
      expect(a.accept(frag(1, 2, all.sublist(mid), all)), isEmpty);
      final events = a.accept(frag(0, 2, all.sublist(0, mid), all));
      expect(events.single, isA<WireFrame>());
      expect((events.single as WireFrame).frame['toSeq'], 1);
      // A replayed older ordinal is dropped.
      expect(a.accept(frag(0, 2, all.sublist(0, mid), all)), isEmpty);
    });

    test('checksum mismatch is a fault', () {
      final a = TopicWireAssembler();
      final all = utf8.encode('{"a":1}');
      final bad = frag(0, 1, utf8.encode('{"a":2}'), all);
      expect(a.accept(bad).single, isA<WireFault>());
    });
  });

  group('TopicRouter', () {
    test('stages frames that arrive before the subscribe ACK', () {
      final ctx = FakeContext();
      final store = SessionsIndexStore(ctx);
      final router = ctx.router..register(store);
      router.beginSubscribe(store);
      // Delivered via the private accept path through a fake stream.
      final wire = {
        'wireVersion': 3,
        'kind': 'complete',
        'deliveryKind': 'initial',
        'logicalFrameId': 'x',
        'logicalFrameOrdinal': 1,
        'topic': store.topic,
        'subscriptionId': 'sub-1',
        'frame': {
          'topic': store.topic,
          'subscriptionId': 'sub-1',
          'fromSeq': 0,
          'toSeq': 0,
          'payload': {
            'kind': 'snapshot',
            'snapshot': {'logEpoch': 'e', 'sessions': []}
          }
        },
      };
      router.debugAccept(wire);
      expect(store.hasState, isFalse);
      router.bind(store, 'sub-1');
      expect(store.hasState, isTrue);
      store.dispose();
    });
  });

  group('DeviceLink', () {
    test('parses zcode --web links', () {
      final link = DeviceLink.tryParse('http://192.168.1.8:3030/?token=abc')!;
      expect(link.webSocketUri.toString(), 'ws://192.168.1.8:3030/ws?token=abc');
      expect(link.serverInfoUri.toString(), 'http://192.168.1.8:3030/api/server-info?token=abc');
      expect(link.displayHost, '192.168.1.8:3030');
    });

    test('adds a scheme and keeps sub paths (reverse proxy)', () {
      expect(DeviceLink.tryParse('10.0.0.2:4000')!.webSocketUri.toString(), 'ws://10.0.0.2:4000/ws');
      final proxied = DeviceLink.tryParse('https://example.com/zcode/?token=t')!;
      expect(proxied.webSocketUri.toString(), 'wss://example.com/zcode/ws?token=t');
    });

    test('parses remote-control relay links', () {
      final link = DeviceLink.tryParse(
          'https://zcode.z.ai/remote/v4?sid=d_test&hash=h4sh%2FValue%3D&t=1700000000000&mid=m-1&name=Desk&app_version=3.14.3')!;
      expect(link.isRelay, isTrue);
      expect(link.sid, 'd_test');
      expect(link.passHash, 'h4sh/Value=');
      expect(link.issuedAt, 1700000000000);
      expect(link.webSocketUri.toString(), 'wss://zcode.z.ai/ws?mid=m-1');
      expect(link.displayHost, 'Desk · zcode.z.ai');
      expect(DeviceLink.tryParse(link.canonical), link);
      // A fresh link for the same desktop replaces the stored one.
      final rotated = DeviceLink.tryParse('https://zcode.z.ai/remote/v4?sid=d_new&hash=x&t=2&mid=m-1')!;
      expect(rotated.identity, link.identity);
      expect(rotated == link, isFalse);
    });

    test('rejects incomplete and unknown links', () {
      expect(DeviceLink.parse('https://zcode.z.ai/remote/v4?sid=a&hash=b').error, 'relayIncomplete');
      expect(DeviceLink.parse('ftp://x').error, 'invalid');
    });
  });

  test('uuidv7 is time ordered and well formed', () {
    final a = uuidv7(DateTime.fromMillisecondsSinceEpoch(1000));
    final b = uuidv7(DateTime.fromMillisecondsSinceEpoch(2000));
    expect(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$').hasMatch(a), isTrue);
    expect(a.compareTo(b) < 0, isTrue);
  });

  test('buildTurns separates work from the final answer', () {
    final turns = buildTurns([
      row(1, 'turnHeader', {'state': 'completedSuccess', 'activeMs': 2000}),
      row(2, 'userInput', {'text': 'q'}),
      row(3, 'reasoning', {'text': 'think', 'state': 'complete'}),
      row(4, 'assistantText', {'text': 'let me', 'state': 'complete'}),
      row(5, 'toolCall', {'toolName': 'Bash', 'input': {'command': 'ls'}}),
      row(6, 'assistantText', {'text': 'done', 'state': 'complete'}),
    ]);
    expect(turns.single.inputs.length, 1);
    expect(turns.single.work.map((r) => r['rowId']), [3, 4, 5]);
    expect(turns.single.answer?['rowId'], 6);
    expect(turns.single.durationMs, 2000);
    expect(toolSummary(turns.single.work[2]), 'ls');
  });

  test('conversation store notifies once per burst', () async {
    final store = ConversationStore(FakeContext(), 's1');
    var n = 0;
    store.addListener(() => n++);
    store.onFrame(snapshotFrame([row(1, 'turnHeader')]), 'initial');
    store.onFrame(deltaFrame(5, 6, [
      {'op': 'state.updated', 'patch': {'revision': 4}}
    ]), 'online');
    await Future<void>.delayed(Duration.zero);
    expect(n, 1);
    expect(store.revision, 4);
    store.dispose();
  });
}
