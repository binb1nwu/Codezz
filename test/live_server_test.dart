// End-to-end check against a real ZCode Web server. Skipped unless
// CODEZZ_TEST_LINK is set, e.g.
//   CODEZZ_TEST_LINK='http://127.0.0.1:3030/?token=…' flutter test test/live_server_test.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:codezz/core/link/device_link.dart';
import 'package:codezz/core/v4/synced_topic.dart';
import 'package:codezz/state/device_registry.dart';
import 'package:codezz/state/device_session.dart';
import 'package:codezz/state/log_store.dart';

Future<void> waitFor(bool Function() cond, {Duration timeout = const Duration(seconds: 60)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  final raw = Platform.environment['CODEZZ_TEST_LINK'];
  test('create a task and stream the reply', () async {
    final link = DeviceLink.tryParse(raw!)!;
    final logs = LogStore();
    final session = DeviceSession(
      Device(id: 't', link: link, addedAt: 0),
      clientId: 'client-test',
      appVersion: 'test',
      logs: logs,
    )..start();
    await waitFor(() => session.workspace != null);
    final ws = session.workspace!;
    await waitFor(() => ws.sessionsIndex.status == TopicStatus.live);
    final before = ws.sessionsIndex.sessions.length;

    final id = await ws.createTask('hello from dart test');
    final conv = ws.conversation(id);
    await waitFor(() => conv.rows.any((r) => r['kind'] == 'assistantText' && r['state'] == 'complete'));
    final text = conv.rows.lastWhere((r) => r['kind'] == 'assistantText')['text'] as String;
    expect(text, contains('mock'));
    expect(conv.rows.any((r) => r['kind'] == 'userInput'), isTrue);
    await waitFor(() => !conv.running);
    await waitFor(() => ws.sessionsIndex.sessions.length > before);

    // Follow-up message on the same session.
    await conv.sendText('second message');
    await waitFor(() => conv.rows.where((r) => r['kind'] == 'userInput').length == 2);
    await waitFor(() => !conv.running && conv.rows.last['kind'] != 'userInput');

    // Reconnect: the store must resume from its watermark.
    final rowsBefore = conv.rows.length;
    final gen = session.connection.generation;
    session.connection.forceReconnect();
    await waitFor(() => session.connection.generation > gen + 1 && session.status.isOnline);
    await waitFor(() => conv.status == TopicStatus.live && ws.sessionsIndex.status == TopicStatus.live);
    expect(conv.rows.length, rowsBefore);
    await conv.sendText('after reconnect');
    await waitFor(() => conv.rows.where((r) => r['kind'] == 'userInput').length == 3);
    await waitFor(() => !conv.running && conv.rows.last['kind'] == 'assistantText');

    // Tool call + permission prompt.
    await conv.sendText('please run a tool');
    await waitFor(() => conv.pendingInteractions.isNotEmpty || conv.rows.any((r) => r['kind'] == 'toolCall' && r['status'] == 'success'),
        timeout: const Duration(seconds: 60));
    for (final p in conv.pendingInteractions) {
      // ignore: avoid_print
      print('pending interaction: ${p['kind']} ${(p['payload'] as Map)['toolName']} options=${(p['payload'] as Map)['options']}');
    }
    if (conv.pendingInteractions.isNotEmpty) {
      final p = conv.pendingInteractions.first;
      final options = ((p['payload'] as Map)['options'] as List?) ?? const [];
      final allow = options.cast<Map>().firstWhere((o) => o['kind'] == 'allowOnce', orElse: () => options.first as Map);
      await conv.resolveInteraction(p['interactionId'] as String, {'optionId': allow['optionId']});
    }
    await waitFor(() => conv.rows.any((r) => r['kind'] == 'toolCall' && (r['status'] == 'success' || r['status'] == 'error')));
    await waitFor(() => !conv.running);
    // ignore: avoid_print
    print(logs.lines.join('\n'));
    // ignore: avoid_print
    print('rows: ${conv.rows.map((r) => r['kind']).join(',')}');
    session.dispose();
  }, skip: raw == null ? 'CODEZZ_TEST_LINK not set' : false, timeout: const Timeout(Duration(minutes: 4)));
}
