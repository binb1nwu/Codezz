// Read-only end-to-end check through ZCode's remote-control relay. Skipped
// unless CODEZZ_RELAY_LINK is set to a link copied from the desktop, e.g.
//   CODEZZ_RELAY_LINK='https://zcode.z.ai/remote/v4?sid=…&hash=…&t=…&mid=…' \
//     flutter test test/live_relay_test.dart
// It never creates or changes tasks on the desktop.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:codezz/core/link/device_link.dart';
import 'package:codezz/core/v4/synced_topic.dart';
import 'package:codezz/state/device_registry.dart';
import 'package:codezz/state/device_session.dart';
import 'package:codezz/state/log_store.dart';
import 'package:codezz/state/task_list_store.dart';

Future<void> waitFor(bool Function() cond, {Duration timeout = const Duration(seconds: 60)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  final raw = Platform.environment['CODEZZ_RELAY_LINK'];
  test('connects through the relay, lists tasks and loads a conversation', () async {
    final link = DeviceLink.tryParse(raw!)!;
    expect(link.isRelay, isTrue);
    final logs = LogStore();
    final session = DeviceSession(
      Device(id: 't', link: link, addedAt: 0),
      clientId: 'client-relay-test',
      appVersion: 'test',
      logs: logs,
    )..start();
    try {
      await waitFor(() => session.workspace != null);
      final ws = session.workspace!;
      await waitFor(() => ws.sessionsIndex.status == TopicStatus.live);
      await waitFor(() => ws.tasks.items(TaskListKind.active).isNotEmpty);
      final tasks = ws.tasks.items(TaskListKind.active);
      // ignore: avoid_print
      print('workspace ${ws.workspace.label}: ${tasks.length} tasks, '
          '${session.models.providers.length} model providers, ${session.workspaces.length} workspaces');

      final conv = ws.conversation(tasks.first.taskId);
      await waitFor(() => conv.status == TopicStatus.live && conv.rows.isNotEmpty);
      // ignore: avoid_print
      print('conversation "${tasks.first.title}": ${conv.rows.length} rows');

      // Moving the bridge to another local workspace keeps things working.
      final other = session.workspaces.where((w) => w.connected && w.key != ws.workspace.key).toList();
      for (final target in other) {
        await session.selectWorkspace(target);
        await waitFor(() => session.workspace?.workspace.key == target.key);
        final next = session.workspace!;
        await waitFor(() => next.sessionsIndex.status == TopicStatus.live);
        await waitFor(() => next.tasks.items(TaskListKind.active).isNotEmpty, timeout: const Duration(seconds: 20))
            .catchError((Object _) {});
        // ignore: avoid_print
        print('switched to ${next.workspace.label} (${next.workspace.kind}): '
            '${next.tasks.items(TaskListKind.active).length} tasks');
      }

      // A forced reconnect re-authenticates and resumes the topics.
      final gen = session.connection.generation;
      session.connection.forceReconnect();
      await waitFor(() => session.connection.generation > gen + 1 && session.status.isOnline);
      await waitFor(() => session.workspace!.sessionsIndex.status == TopicStatus.live);
    } catch (_) {
      // ignore: avoid_print
      print(logs.lines.join('\n'));
      rethrow;
    } finally {
      session.dispose();
    }
  }, skip: raw == null ? 'CODEZZ_RELAY_LINK not set' : false, timeout: const Timeout(Duration(minutes: 3)));
}
