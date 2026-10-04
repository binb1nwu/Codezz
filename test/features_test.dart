import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:codezz/core/v4/conversation_store.dart';
import 'package:codezz/core/v4/synced_topic.dart';
import 'package:codezz/core/v4/topic_router.dart';
import 'package:codezz/core/zcode/server_info.dart';
import 'package:codezz/core/zcode/zcode_api.dart';
import 'package:codezz/state/model_catalog.dart';
import 'package:codezz/state/attachments.dart';
import 'package:codezz/state/plan_usage.dart';
import 'package:codezz/state/side_pane.dart';
import 'package:codezz/ui/conversation/add_context_sheet.dart';
import 'package:codezz/ui/conversation/context_usage.dart';
import 'package:codezz/ui/conversation/plan_usage_section.dart';
import 'package:codezz/ui/conversation/rows.dart';
import 'package:codezz/ui/conversation/scroll_to_bottom.dart';
import 'package:codezz/ui/side_pane/review_view.dart';
import 'package:codezz/ui/theme/tokens.dart';

void main() {
  group('coding-plan quota', () {
    test('only coding-plan providers have an account to query', () {
      expect(planAccountAccess('account:zai-individual-coding-plan'),
          {'type': 'zhipu-account', 'family': 'zai', 'planKind': 'individual-coding-plan'});
      expect(planAccountAccess('account:bigmodel-start-plan')?['planKind'], 'start-plan');
      expect(planAccountAccess('account:bigmodel-team-coding-plan'), isNull);
      expect(planAccountAccess('openai'), isNull);
    });

    test('individual plan: 5-hour, weekly, tool-call and MCP quotas as remaining shares', () {
      final reset = DateTime(2026, 10, 7, 16, 5).millisecondsSinceEpoch;
      final snap = PlanSnapshot.fromJson({
        'provider': {'id': 'account:zai-individual-coding-plan'},
        'quota': {
          'limits': [
            {'type': 'TOKENS_LIMIT', 'unit': 6, 'percentage': 40, 'nextResetTime': reset},
            {'type': 'CREDIT_LIMIT', 'unit': 3, 'number': 5, 'percentage': 97.5, 'nextResetTime': reset},
            {'type': 'TIME_LIMIT', 'unit': 5, 'number': 1, 'percentage': 0},
          ],
        },
        'mcpQuota': {
          'aggregate': {'type': 'TIME_LIMIT', 'unit': 1, 'percentage': 10},
        },
      }, 'account:zai-individual-coding-plan');
      expect(snap.active, isTrue);
      expect([for (final q in snap.quotas) q.key], ['fiveHour', 'weekly', 'toolCalls', 'mcp']);
      expect([for (final q in snap.quotas) q.remaining], [2.5, 60, 100, 90]);
      expect(snap.ringQuota?.key, 'fiveHour');
      expect(quotaPercentText(2.5), '2.5%');
      expect(quotaPercentText(60), '60%');
      expect(quotaPercentText(null), '--');
      expect(quotaResetText(snap.quotas[0], zh: true), '16:05');
      expect(quotaResetText(snap.quotas[1], zh: true), '10月7日');
      expect(quotaResetText(snap.quotas[1], zh: false), 'Oct 7');
    });

    test('start plan: per-model balances from remaining / total', () {
      final snap = PlanSnapshot.fromJson({
        'provider': {'id': 'account:zai-start-plan'},
        'quota': {
          'limits': [
            {
              'type': 'TOKENS_LIMIT',
              'unit': 1,
              'number': 200,
              'remaining': 66,
              'usageDetails': [
                {'modelCode': 'model:glm-5.3-flash'}
              ],
            },
            {'type': 'TOKENS_LIMIT', 'unit': 0, 'remaining': 0, 'usageDetails': []},
          ],
        },
      }, 'account:zai-start-plan');
      expect(snap.quotas, hasLength(1));
      expect(snap.quotas.single.label, 'GLM-5.3-FLASH');
      expect(snap.quotas.single.remaining, 33);
      expect(snap.ringQuota?.key, 'balance');
    });

    test('a snapshot of another provider or without a plan is not active', () {
      expect(PlanSnapshot.fromJson({'provider': {'id': 'x'}, 'quota': {}}, 'y').active, isFalse);
      final none = PlanSnapshot.fromJson(
          {'provider': {'id': 'y'}, 'unavailableReason': 'no_plan', 'quota': {}}, 'y');
      expect(none.active, isFalse);
      expect(none.unavailableReason, 'no_plan');
    });

    test('store reuses a fresh snapshot and backs off after failures', () async {
      const id = 'account:zai-individual-coding-plan';
      var now = DateTime(2026, 9, 30, 12);
      final api = _FakeApi();
      final store = PlanUsageStore(() => api, now: () => now);

      await store.access(id);
      expect(api.calls, 1);
      expect(store.entry(id)!.snapshot!.active, isTrue);
      // Opened again within a minute: the snapshot is reused.
      now = now.add(const Duration(seconds: 30));
      await store.access(id);
      expect(api.calls, 1);
      // An explicit refresh always fetches.
      await store.refresh(id);
      expect(api.calls, 2);

      // A failure keeps the old snapshot and backs off for 30 s.
      api.fail = true;
      now = now.add(const Duration(minutes: 2));
      await store.access(id);
      expect(api.calls, 3);
      expect(store.entry(id)!.error, isNotNull);
      expect(store.entry(id)!.snapshot, isNotNull);
      now = now.add(const Duration(seconds: 20));
      await store.access(id);
      expect(api.calls, 3);
      now = now.add(const Duration(seconds: 15));
      await store.access(id);
      expect(api.calls, 4);

      // Offline: nothing is fetched.
      expect(PlanUsageStore(() => null).entry(id), isNull);
    });

    testWidgets('header quota follows the plan of the composer on screen', (tester) async {
      const id = 'account:zai-individual-coding-plan';
      final api = _FakeApi()
        ..limits = [
          {'type': 'TOKENS_LIMIT', 'unit': 6, 'percentage': 40},
          {'type': 'CREDIT_LIMIT', 'unit': 3, 'number': 5, 'percentage': 2},
        ];
      final store = PlanUsageStore(() => api);
      await tester.pumpWidget(MaterialApp(
        theme: buildZTheme(Brightness.light),
        home: Scaffold(
          body: HeaderPlanQuota(
            plans: store,
            usage: () => ValueNotifier(const ContextUsage(used: 50000, size: 200000)),
          ),
        ),
      ));
      expect(find.byType(Text), findsNothing);

      await tester.runAsync(() => store.access(id));
      store.shown = id;
      await tester.pump();
      expect(find.text('5h'), findsOneWidget);
      expect(find.text('98%'), findsOneWidget);
      expect(find.text('wk'), findsOneWidget);
      expect(find.text('60%'), findsOneWidget);
      expect(find.byType(QuotaMiniBar), findsNWidgets(2));

      // Tapping opens the ring's usage card: context and quota.
      await tester.tap(find.text('5h'));
      await tester.pumpAndSettle();
      expect(find.byType(ContextUsageCard), findsOneWidget);
      expect(find.text('50K/200K (25%)'), findsOneWidget);
      expect(find.text('Usage remaining'), findsOneWidget);
      Navigator.of(tester.element(find.byType(ContextUsageCard))).pop();
      await tester.pumpAndSettle();

      // A model outside the coding plan hides it again.
      store.shown = null;
      await tester.pump();
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('quota section renders bars for each quota', (tester) async {
      final entry = PlanUsageEntry()
        ..snapshot = const PlanSnapshot(active: true, quotas: [
          PlanQuota(key: 'fiveHour', remaining: 80),
          PlanQuota(key: 'weekly', remaining: 55),
        ]);
      await tester.pumpWidget(MaterialApp(
        theme: buildZTheme(Brightness.dark),
        home: Scaffold(body: PlanUsageSection(entry: entry, startPlan: false, onRefresh: () {})),
      ));
      expect(find.text('Usage remaining'), findsOneWidget);
      expect(find.text('5 hours'), findsOneWidget);
      expect(find.text('Weekly'), findsOneWidget);
      expect(find.byType(QuotaBar), findsNWidgets(2));
    });
  });

  group('composer "+" menu', () {
    test('mentions use ZCode markdown', () {
      expect(fileMention({'name': 'main.dart', 'relativePath': 'lib/main.dart', 'type': 'file'}),
          '[main.dart](./lib/main.dart)');
      expect(fileMention({'name': 'lib', 'relativePath': 'lib', 'type': 'directory'}), '[lib/](./lib/)');
      expect(fileMention({'name': 'a[1].md', 'relativePath': 'docs/a[1].md', 'type': 'file'}),
          r'[a\[1\].md](./docs/a\[1\].md)');
      expect(sessionMention('sess_1', 'Fix login'), '[#Fix login](#sess_1)');
      expect(sessionMention('sess_1', ''), '#sess_1');
      expect(pluginMention({'pluginId': 'p1', 'name': 'pdf', 'displayName': 'PDF'}), '[@PDF](plugin://p1)');
    });

    test('goal commands', () {
      expect(goalObjective('/goal ship the release'), 'ship the release');
      expect(goalObjective('  /target  tidy up '), 'tidy up');
      expect(goalObjective('/goal replace new aim'), 'new aim');
      expect(goalObjective('/goal'), '');
      expect(goalObjective('/goal pause'), isNull);
      expect(goalObjective('/goals are nice'), isNull);
      expect(goalObjective('hello /goal x'), isNull);
    });

    test('attachments: inline media, truncated text, unreadable binaries', () {
      final png = ComposerAttachment.fromFile('shot.PNG', Uint8List(10), truncatedNote: '[cut]');
      expect(png.mime, 'image/png');
      expect(png.isImage, isTrue);
      expect(png.problem, isNull);

      final big = ComposerAttachment.fromFile(
          'clip.mp4', Uint8List(AttachmentLimits.maxInlineBytes + 1), truncatedNote: '[cut]');
      expect(big.problem, AttachmentProblem.tooLarge);

      final long = 'x' * (AttachmentLimits.maxTextChars + 5);
      final text = ComposerAttachment.fromFile('log.txt', Uint8List.fromList(utf8.encode(long)),
          truncatedNote: '[cut]');
      expect(utf8.decode(text.content!), '${'x' * AttachmentLimits.maxTextChars}\n\n[cut]');

      final bin = ComposerAttachment.fromFile('app.exe', Uint8List(4), truncatedNote: '[cut]');
      expect(bin.problem, AttachmentProblem.unreadable);
      expect(bin.status, AttachmentStatus.failed);
    });
  });

  test('sendText carries the composer selection (ZCode applies it with the message)', () async {
    final api = _CommandApi();
    final store = ConversationStore(_Ctx(api), 's1');
    await store.sendText('hi',
        modelSelection: const ModelSelection('p', 'GLM-5.3', 'low').toJson(), mode: 'plan');
    final payload = api.envelopes.single['payload'] as Map;
    expect(api.envelopes.single['type'], 'sendText');
    expect(payload['modelSelection'], {
      'providerId': 'p',
      'modelId': 'GLM-5.3',
      'options': {'reasoningLevel': 'low'},
    });
    expect(payload['mode'], 'plan');
    expect(payload['planEnabled'], true);
    // No reasoning level: no options.
    expect(const ModelSelection('p', 'm', '').toJson().containsKey('options'), isFalse);
    store.dispose();
  });

  testWidgets('scroll-to-bottom button appears away from the newest message', (tester) async {
    final controller = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildZTheme(Brightness.light),
        home: Scaffold(
          body: Stack(
            children: [
              ListView.builder(
                controller: controller,
                reverse: true,
                itemCount: 100,
                itemBuilder: (_, i) => SizedBox(height: 40, child: Text('')),
              ),
              Positioned(right: 10, bottom: 2, child: ScrollToBottomButton(controller: controller)),
            ],
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.arrow_downward_rounded), findsNothing);
    controller.jumpTo(40);
    await tester.pump();
    expect(find.byIcon(Icons.arrow_downward_rounded), findsNothing);
    controller.jumpTo(600);
    await tester.pump();
    expect(find.byIcon(Icons.arrow_downward_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_downward_rounded));
    await tester.pump();
    expect(controller.offset, 0);
    expect(find.byIcon(Icons.arrow_downward_rounded), findsNothing);
  });

  testWidgets('streaming reasoning stays one scrolling line until opened', (tester) async {
    final text = List.generate(40, (i) => 'step $i of the plan').join('\n');
    Widget host(String state) => MaterialApp(
      theme: buildZTheme(Brightness.light),
      home: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(width: 300, child: ReasoningRow(row: {'text': text, 'state': state})),
        ),
      ),
    );
    await tester.pumpWidget(host('streaming'));
    final line = find.textContaining('step 39 of the plan');
    expect(line, findsOneWidget);
    expect(tester.getSize(line).height, lessThan(30));
    expect(tester.widget<Text>(line).data, isNot(contains('\n')));
    expect(find.byType(SingleChildScrollView), findsNWidgets(2));

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pump();
    expect(find.text(text.trim()), findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsOneWidget);

    await tester.pumpWidget(host('complete'));
    await tester.tap(find.byIcon(Icons.expand_less));
    await tester.pump();
    expect(find.textContaining('step 39'), findsNothing);
  });

  group('side pane', () {
    test('review sources and patch lines', () {
      final status = {
        'unstagedChanges': [
          {'path': 'a.dart'}
        ],
        'stagedChanges': [
          {'path': 'b.dart'}
        ],
        'branchComparison': {
          'changes': [
            {'path': 'c.dart'}
          ]
        },
      };
      expect(reviewChanges(status, 'unstaged').single['path'], 'a.dart');
      expect(reviewChanges(status, 'staged').single['path'], 'b.dart');
      expect(reviewChanges(status, 'branch').single['path'], 'c.dart');
      expect(
        patchLines('diff --git a/x b/x\nindex 1..2\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n\n'),
        ['@@ -1 +1 @@', '-old', '+new'],
      );
    });

    test('tabs: one review tab, closing picks a neighbour', () {
      final pane = SidePane();
      pane.openReview();
      pane.openReview();
      expect(pane.tabs, hasLength(1));
      expect(pane.visible, isTrue);
      expect(pane.activeId, 'review');
      pane.hide();
      expect(pane.visible, isFalse);
      pane.closeTab('review');
      expect(pane.tabs, isEmpty);
      expect(pane.activeId, isNull);
      pane.dispose();
    });
  });
}

class _FakeApi implements ZCodeApi {
  int calls = 0;
  bool fail = false;
  List<Map<String, Object?>> limits = const [];

  @override
  Future<Map<String, dynamic>> entitlementSnapshot(String providerId, Map<String, Object?> accountAccess) async {
    calls++;
    if (fail) throw StateError('offline');
    return {
      'provider': {'id': providerId},
      'quota': {'limits': limits},
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Ctx implements WorkspaceContext {
  _Ctx(this.api);
  @override
  final ZCodeApi api;
  @override
  WorkspaceRef get workspace => const WorkspaceRef(path: '/w', label: 'w');
  @override
  TopicRouter get router => TopicRouter(workspace);
  @override
  Stream<ZCodeApi> get onApi => const Stream.empty();
  @override
  void log(String line) {}
}

class _CommandApi implements ZCodeApi {
  final envelopes = <Map<String, Object?>>[];
  @override
  String get clientId => 'c1';
  @override
  Future<Map<String, dynamic>> sendCommand(WorkspaceRef ws, Map<String, Object?> envelope) async {
    envelopes.add(envelope);
    return {'status': 'accepted'};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
