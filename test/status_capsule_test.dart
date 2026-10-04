import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:codezz/core/v4/conversation_store.dart';
import 'package:codezz/core/v4/synced_topic.dart';
import 'package:codezz/core/v4/topic_router.dart';
import 'package:codezz/core/zcode/server_info.dart';
import 'package:codezz/core/zcode/zcode_api.dart';
import 'package:codezz/state/device_session.dart';
import 'package:codezz/state/side_pane.dart';
import 'package:codezz/ui/conversation/status_capsule.dart';
import 'package:codezz/ui/theme/tokens.dart';
import 'package:codezz/ui/widgets/tucked_below.dart';

ConversationStore _store(Map<String, dynamic> state) =>
    ConversationStore(_Ctx(), 's1')..state = state;

void main() {
  test('capsule shows the current todo first', () {
    final m = StatusModel.from(
      _store({
        'plan': {
          'items': [
            {'content': 'a', 'status': 'completed'},
            {'content': 'b', 'status': 'inProgress'},
            {'content': 'c', 'status': 'pending'},
          ]
        },
        'goal': {'status': 'active', 'objective': 'ship'},
      }),
      const GitStatus(added: 3, removed: 1),
    );
    final seg = m.capsule()!;
    expect(seg.kind, CapsuleKind.todo);
    expect(seg.text, 'b');
    expect(m.todosDone, 1);
  });

  test('then an active goal, git changes, a finished todo, running work', () {
    expect(
      StatusModel.from(_store({'goal': {'status': 'paused', 'objective': ' ship ', 'summaryTitle': ''}}), null)
          .capsule()!
          .text,
      'ship',
    );
    final git = StatusModel.from(_store({}), const GitStatus(added: 2, removed: 5)).capsule()!;
    expect((git.kind, git.added, git.removed), (CapsuleKind.git, 2, 5));
    final done = StatusModel.from(
      _store({
        'plan': {
          'items': [
            {'content': 'a', 'status': 'completed'},
            {'content': 'b', 'status': 'completed'},
          ]
        }
      }),
      const GitStatus(),
    ).capsule()!;
    expect((done.kind, done.text), (CapsuleKind.done, 'b'));
    final running = StatusModel.from(
      _store({
        'backgroundWorks': [
          {'workId': 'w1', 'kind': 'bash', 'title': 'npm test', 'status': 'running', 'startedAt': 1},
          {'workId': 'w2', 'kind': 'bash', 'title': 'old', 'status': 'failed'},
          {'workId': 'w3', 'kind': 'subagent', 'childSessionId': 'c1', 'status': 'running', 'cancellable': true},
        ],
        'subagents': {
          'running': [
            {'childSessionId': 'c1', 'title': 'Explore', 'subagentType': 'explore', 'status': 'running'},
          ]
        },
      }),
      null,
    );
    final seg = running.capsule()!;
    expect((seg.kind, seg.bash, seg.agents), (CapsuleKind.running, 1, 1));
    // The subagent is stopped through its single background work.
    expect(running.agents.single.workId, 'w3');
    expect(running.agents.single.title, 'Explore');
    // A clean repo and nothing else: no capsule at all.
    expect(StatusModel.from(_store({}), const GitStatus()).isEmpty, isTrue);
  });

  test('git status sums unstaged and staged lines', () {
    final git = GitStatus.fromRefresh({
      'summary': {'isGitAvailable': true, 'isRepository': true, 'branchName': 'main'},
      'unstagedChanges': [
        {'added': 3, 'removed': 1},
      ],
      'stagedChanges': [
        {'added': 2, 'removed': 0},
      ],
    })!;
    expect((git.branch, git.added, git.removed), ('main', 5, 1));
    expect(GitStatus.fromRefresh({'summary': {'isRepository': false}}), isNull);
  });

  test('long todo lists fold around the current item', () {
    List<TodoItem> todos(List<String> s) => [for (final x in s) TodoItem(x, x)];
    expect(todoWindow(todos(['completed', 'inProgress', 'pending'])), isNull);
    final list = todos(['completed', 'completed', 'completed', 'inProgress', 'pending', 'pending', 'pending', 'pending']);
    expect(todoWindow(list), (3, 6));
    final allDone = todos(List.filled(8, 'completed'));
    expect(todoWindow(allDone), (5, 8));
    final nearEnd = todos([...List.filled(7, 'completed'), 'inProgress']);
    expect(todoWindow(nearEnd), (5, 8));
  });

  testWidgets('a tucked strip stays tappable above the widget pulled over it', (tester) async {
    final taps = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: TuckedBelow(
            top: Container(
              height: 80,
              alignment: Alignment.topCenter,
              child: TextButton(onPressed: () => taps.add('queue'), child: const Text('queue')),
            ),
            child: SizedBox(
              height: 60,
              child: TextButton(onPressed: () => taps.add('composer'), child: const Text('composer')),
            ),
          ),
        ),
      ),
    ));
    // 80 + 60 - 28.
    expect(tester.getSize(find.byType(TuckedBelow)).height, 112);
    expect(tester.getTopLeft(find.text('composer')).dy, greaterThan(tester.getBottomLeft(find.text('queue')).dy));
    await tester.tap(find.text('queue'));
    await tester.tap(find.text('composer'));
    expect(taps, ['queue', 'composer']);
    // The composer's top edge overlaps the strip by 28 px.
    final composerTop = tester.getTopLeft(find.byType(PullUp)).dy;
    expect(tester.getBottomLeft(find.byType(PullUp)).dy - composerTop, 32);
  });

  testWidgets('capsule expands into the panel and collapses back', (tester) async {
    final store = _store({
      'plan': {
        'items': [
          {'content': 'Write tests', 'status': 'inProgress'},
          {'content': 'Ship', 'status': 'pending'},
        ]
      },
    });
    final expanded = ValueNotifier(false);
    await tester.pumpWidget(MaterialApp(
      theme: buildZTheme(Brightness.light),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topRight,
          child: StatusCapsule(store: store, workspace: _FakeWorkspace(), expanded: expanded),
        ),
      ),
    ));
    expect(find.text('Write tests'), findsOneWidget);
    expect(find.text('Progress'), findsNothing);

    await tester.tap(find.text('Write tests'));
    await tester.pumpAndSettle();
    expect(expanded.value, isTrue);
    expect(find.text('Progress'), findsOneWidget);
    expect(find.text('0/2'), findsOneWidget);
    expect(find.text('Ship'), findsOneWidget);

    await tester.tap(find.byTooltip('Collapse to capsule'));
    await tester.pumpAndSettle();
    expect(find.text('Progress'), findsNothing);
  });
}

class _Ctx implements WorkspaceContext {
  @override
  WorkspaceRef get workspace => const WorkspaceRef(path: '/w', label: 'w');
  @override
  TopicRouter get router => TopicRouter(workspace);
  @override
  ZCodeApi? get api => null;
  @override
  Stream<ZCodeApi> get onApi => const Stream.empty();
  @override
  void log(String line) {}
}

class _FakeWorkspace implements WorkspaceSession {
  @override
  ZCodeApi? get api => null;
  @override
  WorkspaceRef get workspace => const WorkspaceRef(path: '/w', label: 'w');
  @override
  final SidePane sidePane = SidePane();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
