import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:codezz/core/zcode/server_info.dart';
import 'package:codezz/core/zcode/zcode_api.dart';
import 'package:codezz/state/app_state.dart';
import 'package:codezz/state/device_session.dart';
import 'package:codezz/state/side_pane.dart';
import 'package:codezz/ui/conversation/rows.dart';
import 'package:codezz/ui/conversation/timeline.dart';
import 'package:codezz/ui/home/task_notifications.dart';
import 'package:codezz/ui/l10n.dart';
import 'package:codezz/ui/side_pane/side_pane_view.dart';
import 'package:codezz/ui/theme/tokens.dart';
import 'package:codezz/ui/widgets/common.dart';
import 'package:codezz/ui/widgets/expand_anchor.dart';
import 'package:codezz/ui/conversation/tool_details.dart';

void main() {
  Widget app(Widget home) => MaterialApp(theme: buildZTheme(Brightness.light), home: home);

  testWidgets('the side pane is a page: back returns to the conversation', (tester) async {
    final ws = _FakeWorkspace();
    await tester.pumpWidget(app(Scaffold(
      body: SidePaneHost(workspace: ws, child: const Text('conversation')),
    )));
    ws.sidePane.show();
    await tester.pumpAndSettle();
    expect(find.byType(SidePanePage), findsOneWidget);
    expect(find.text('conversation'), findsNothing);

    // System back pops the page and hides the pane; the app stays open.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SidePanePage), findsNothing);
    expect(find.text('conversation'), findsOneWidget);
    expect(ws.sidePane.visible, isFalse);

    // Its own back button hides the pane, which pops the page.
    ws.sidePane.show();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(SidePanePage), findsNothing);
    expect(ws.sidePane.visible, isFalse);
  });

  testWidgets('a running tool call shows its spinner on a line of its own', (tester) async {
    await tester.pumpWidget(app(const Scaffold(
      body: ToolCallRow(row: {
        'toolName': 'Bash',
        'status': 'running',
        'input': {'command': 'sleep 580; cat /mnt/data/a/very/long/path/that/fills/the/row'},
      }),
    )));
    final name = tester.getRect(find.text('Bash'));
    final icon = tester.getRect(find.byIcon(Icons.terminal_rounded));
    final spinner = tester.getRect(find.byType(ZSpinner));
    expect(spinner.top, greaterThanOrEqualTo(name.bottom));
    // In the icon column, like the other rows' icons.
    expect(spinner.center.dx, closeTo(icon.center.dx, 0.5));
  });

  group('tool details follow ZCode', () {
    Future<void> open(WidgetTester tester, Map<String, dynamic> row) async {
      await tester.pumpWidget(app(Scaffold(body: SingleChildScrollView(child: ToolCallRow(row: row)))));
      await tester.tap(find.text('${row['toolName']}'));
      await tester.pumpAndSettle();
    }

    testWidgets('shell: \$ command and output in one card, flush with the icons', (tester) async {
      await open(tester, {
        'toolName': 'Bash',
        'status': 'completed',
        'input': {'command': "bash -lc 'ls -la'"},
        'output': {'text': 'total 0\nfile.txt'},
      });
      expect(find.text(r'$'), findsOneWidget);
      // The wrapper is stripped; the row hides the command while open.
      expect(find.text('ls -la'), findsOneWidget);
      expect(find.text('total 0\nfile.txt'), findsOneWidget);
      final icon = tester.getRect(find.byIcon(Icons.terminal_rounded));
      expect(tester.getRect(find.byType(ShellDetails)).left, icon.left);
    });

    testWidgets('shell without output says so', (tester) async {
      await open(tester, {'toolName': 'Bash', 'status': 'completed', 'input': {'command': 'true'}});
      expect(find.text('No output.'), findsOneWidget);
    });

    testWidgets('read calls do not expand', (tester) async {
      await open(tester, {
        'toolName': 'Read',
        'status': 'completed',
        'input': {'file_path': '/w/a.dart'},
        'output': {'text': 'secret contents'},
      });
      expect(find.text('secret contents'), findsNothing);
    });

    testWidgets('edit: numbered diff without hunk headers', (tester) async {
      await open(tester, {
        'toolName': 'Edit',
        'status': 'completed',
        'input': {'file_path': '/w/a.dart'},
        'display': {
          'kind': 'file_diff',
          'additions': 1,
          'deletions': 1,
          'structuredPatch': [
            {
              'oldStart': 1, 'oldLines': 2, 'newStart': 1, 'newLines': 2,
              'lines': [' keep', '-old', '+new'],
            },
          ],
        },
      });
      expect(find.byType(DiffView), findsOneWidget);
      expect(find.textContaining('@@'), findsNothing);
      for (final t in ['keep', 'old', 'new', '1', '2', '3']) {
        expect(find.text(t), findsOneWidget);
      }
    });

    testWidgets('edit without a display diffs its own input', (tester) async {
      await open(tester, {
        'toolName': 'Edit',
        'status': 'completed',
        'input': {'file_path': '/w/a.py', 'old_string': 'a\nold\nz', 'new_string': 'a\nnew\nz'},
        'output': {'text': 'The file has been updated successfully.'},
      });
      expect(find.byType(DiffView), findsOneWidget);
      expect(find.text('+1'), findsOneWidget);
      expect(find.text('-1'), findsOneWidget);
      expect(find.text('old'), findsOneWidget);
      expect(find.text('new'), findsOneWidget);
      expect(find.textContaining('updated successfully'), findsNothing);
    });

    test('input diffs keep shared lines as context', () {
      final d = inputDiff({
        'input': {'old_string': 'a\nb\nc', 'new_string': 'a\nB\nc'},
      })!;
      expect((d['structuredPatch'] as List).single['lines'], [' a', '-b', '+B', ' c']);
      expect(inputDiff({'input': {'content': 'x\ny'}})!['additions'], 2);
      expect(inputDiff({'input': {'query': 'q'}}), isNull);
    });

    testWidgets('todo: current item and count, expanding to the list', (tester) async {
      final row = {
        'toolName': 'TodoWrite',
        'status': 'completed',
        'input': {
          'todos': [
            {'content': 'Read the code', 'status': 'completed'},
            {'content': 'Fix the bug', 'status': 'in-progress'},
            {'content': 'Ship it', 'status': 'pending'},
            {'content': 'Dropped', 'status': 'weird'},
          ],
        },
        'output': {'text': 'Todos have been modified successfully.'},
      };
      await tester.pumpWidget(app(Scaffold(body: SingleChildScrollView(child: ToolCallRow(row: row)))));
      expect(find.text('Todo'), findsOneWidget);
      expect(find.text('Fix the bug'), findsOneWidget);
      expect(find.text('1/3'), findsOneWidget);

      await tester.tap(find.text('Todo'));
      await tester.pumpAndSettle();
      expect(find.byType(TodoDetails), findsOneWidget);
      expect(find.text('Read the code'), findsOneWidget);
      expect(find.text('Ship it'), findsOneWidget);
      expect(find.text('Dropped'), findsNothing);
      expect(find.textContaining('modified successfully'), findsNothing);
      final done = tester.widget<Text>(find.text('Read the code'));
      expect(done.style!.decoration, TextDecoration.lineThrough);
    });

    testWidgets('other tools: result, then the parameters on demand', (tester) async {
      await open(tester, {
        'toolName': 'mcp__docs__search',
        'status': 'completed',
        'input': {'query': 'flutter'},
        'output': {'text': 'Found 3 pages'},
      });
      expect(find.text('Found 3 pages'), findsOneWidget);
      expect(find.text('Parameters'), findsNothing);
      await tester.tap(find.text('View call details'));
      await tester.pumpAndSettle();
      expect(find.text('Parameters'), findsOneWidget);
      expect(find.textContaining('"query": "flutter"'), findsOneWidget);
    });
  });

  testWidgets('expanding in the reversed timeline opens downwards', (tester) async {
    final controller = ScrollController();
    await tester.pumpWidget(app(Scaffold(
      body: ListView(
        controller: controller,
        reverse: true,
        physics: AnchoredScrollPhysics(correction: ScrollCorrection()),
        children: [
          for (var i = 0; i < 30; i++) SizedBox(height: 40, child: Text('row $i')),
          const ToolCallRow(row: {
            'toolName': 'Bash',
            'status': 'completed',
            'input': {'command': 'ls'},
            'output': {'text': 'a\nb\nc\nd'},
          }),
          for (var i = 30; i < 60; i++) SizedBox(height: 40, child: Text('row $i')),
        ],
      ),
    )));
    controller.jumpTo(1000);
    await tester.pump();
    final before = tester.getTopLeft(find.text('Bash')).dy;
    await tester.tap(find.text('Bash'));
    // One frame: the row must already be in place, not corrected a frame
    // later (which flashes).
    await tester.pump();
    expect(find.byType(ShellDetails), findsOneWidget);
    expect(tester.getTopLeft(find.text('Bash')).dy, closeTo(before, 0.5));
    // The card sits below the row.
    expect(tester.getTopLeft(find.byType(ShellDetails)).dy, greaterThan(before));

    // Collapsing holds it still too.
    await tester.tap(find.text('Bash'));
    await tester.pump();
    expect(find.byType(ShellDetails), findsNothing);
    expect(tester.getTopLeft(find.text('Bash')).dy, closeTo(before, 0.5));
  });

  group('turn duration', () {
    Widget label(TurnDurationLabel l) => app(Scaffold(body: l));

    testWidgets('uses the desktop duration when it has one', (tester) async {
      await tester.pumpWidget(label(const TurnDurationLabel(running: true, durationMs: 65000, startedAt: 0)));
      expect(find.text('Working for 1m 5s'), findsOneWidget);
      await tester.pumpWidget(label(const TurnDurationLabel(running: false, durationMs: 65000)));
      expect(find.text('Worked for 1m 5s'), findsOneWidget);
    });

    testWidgets('counts up from the start while running without one', (tester) async {
      var now = DateTime.fromMillisecondsSinceEpoch(1000000 + 12000);
      await tester.pumpWidget(label(TurnDurationLabel(running: true, startedAt: 1000000, now: () => now)));
      expect(find.text('Working for 12s'), findsOneWidget);
      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Working for 13s'), findsOneWidget);
      // Finished: the ticker stops and the final duration shows.
      await tester.pumpWidget(label(const TurnDurationLabel(running: false, durationMs: 14000, startedAt: 1000000)));
      expect(find.text('Worked for 14s'), findsOneWidget);
    });

    testWidgets('without any timing a running turn just says working', (tester) async {
      await tester.pumpWidget(label(const TurnDurationLabel(running: true)));
      expect(find.text('Working'), findsOneWidget);
    });
  });

  test('the open task survives a restart', () async {
    SharedPreferences.setMockInitialValues({});
    final first = AppState();
    await first.init();
    await first.setSelection('dev|/w', 'task-1');
    await first.setSelection('dev|/other', 'task-2');
    await first.setSelection('dev|/other', null);
    first.dispose();

    final second = AppState();
    await second.init();
    expect(second.selections, {'dev|/w': 'task-1'});
    second.dispose();
  });

  group('task notifications', () {
    test('payloads round-trip, even with "|" in the workspace key', () {
      const t = TaskTarget('dev', 'ssh|host:/w', 'sess_1');
      expect(TaskTarget.decode(t.encode()), t);
      expect(TaskTarget.decode('nope'), isNull);
      expect(TaskTarget.decode(null), isNull);
    });

    test('without a loaded conversation the progress just says working', () {
      const s = S.lang(zh: true);
      final p = TaskProgress.of('Fix CI', null, s);
      expect(p.text, s.working);
      expect(p.total, isNull);
    });
  });
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
