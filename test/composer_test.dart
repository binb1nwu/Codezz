import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:codezz/state/app_state.dart';
import 'package:codezz/state/model_catalog.dart';
import 'package:codezz/state/plan_usage.dart';
import 'package:codezz/state/task_list_store.dart';
import 'package:codezz/ui/conversation/composer.dart';
import 'package:codezz/ui/conversation/context_usage.dart';
import 'package:codezz/ui/theme/tokens.dart';
import 'package:codezz/ui/widgets/glass.dart';

void main() {
  final catalog = ModelCatalog.fromView({
    'providers': [
      {
        'providerId': 'account:bigmodel-individual-coding-plan',
        'providerName': 'BigModel Individual Coding Plan',
        'models': [
          {
            'modelId': 'GLM-5.3',
            'config': {
              'optionSpecs': {
                'reasoningLevel': {
                  'values': ['low', 'high', 'max']
                }
              }
            }
          },
          {'modelId': 'GLM-5.3-Flash', 'config': {}},
        ],
      },
    ],
  });

  Widget host(Widget child) => MaterialApp(
        theme: buildZTheme(Brightness.light),
        home: Scaffold(body: Center(child: SizedBox(width: 360, child: child))),
      );

  testWidgets('toolbar shows the short model name, never the provider', (tester) async {
    await tester.pumpWidget(host(Composer(
      hint: 'hint',
      onSend: (_, __) async => true,
      onMode: (_) {},
      catalog: catalog,
      model: const ModelSelection('account:bigmodel-individual-coding-plan', 'GLM-5.3-Flash'),
      onModel: (_) {},
      reasoningLevels: const ['low', 'high', 'max'],
      reasoning: 'high',
      onReasoning: (_) {},
    )));
    expect(find.text('GLM-5.3-Flash'), findsOneWidget);
    expect(find.textContaining('BigModel'), findsNothing);
    expect(find.byType(ThoughtMeter), findsOneWidget);

    // The picker groups by provider and marks the selected model.
    await tester.tap(find.text('GLM-5.3-Flash'));
    await tester.pumpAndSettle();
    expect(find.text('BigModel Individual Coding Plan'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  test('task titles drop Markdown session links', () {
    expect(plainTitle('[#Fork of 相对动作表征方法探讨](#sess_206dc37a)'), '#Fork of 相对动作表征方法探讨');
    expect(plainTitle('plain  title'), 'plain title');
    expect(plainTitle('[#Fork of X](#sess_206dc37a-2ba4...'), '#Fork of X');
  });

  test('model and reasoning helpers', () {
    expect(shortModelName('account:plan/GLM-5.3'), 'GLM-5.3');
    expect(shortModelName('GLM-5.3'), 'GLM-5.3');
    expect(thoughtRatio('max', const ['low', 'high', 'max']), 1);
    // Known levels keep their strength whatever else the model offers.
    expect(thoughtRatio('low', const ['low', 'high', 'max']), 0.25);
    expect(thoughtRatio('high', const ['low', 'high', 'max']), 0.75);
    expect(thoughtRatio('b', const ['off', 'a', 'b']), 1);
    expect(thoughtRatio('a', const ['off', 'a', 'b']), 0.5);
    expect(thoughtRatio('disabled', const ['disabled', 'enabled']), 0);
  });

  test('context usage follows usage.contextWindow', () {
    expect(ContextUsage.fromUsage(const {}), isNull);
    expect(ContextUsage.fromUsage(const {'contextWindow': null}), isNull);
    expect(ContextUsage.fromUsage(const {'contextWindow': {'usedTokens': 0, 'maxTokens': 200000}}), isNull);

    final u = ContextUsage.fromUsage(const {
      'contextWindow': {
        'usedTokens': 71505,
        'maxTokens': 200000,
        'autoCompactThresholdTokens': null,
        'cache': {'inputTokens': 1, 'cacheReadTokens': 2, 'cacheWriteTokens': 0, 'hitRate': 0.9123},
        'breakdown': [
          {'source': 'system_prompt', 'chars': 1000},
          {'source': 'messages', 'chars': 2000},
          {'source': 'skills', 'chars': 1000},
          {'source': 'messages', 'chars': 1000},
          {'source': 'mcp_tool_schemas', 'chars': 0},
        ],
      },
      'cumulative': {'inputTokens': 0, 'outputTokens': 0, 'cacheReadTokens': 0, 'cacheWriteTokens': 0},
    })!;
    expect(u.ratio, closeTo(0.357525, 1e-9));
    expect(u.hitRate, 0.9123);
    // Merged per source, largest first, ties in ZCode's source order.
    expect([for (final b in u.breakdown) b.source], ['messages', 'system_prompt', 'skills']);
    expect(u.breakdown.first.percent, 0.6);
    expect(contextUsageSummary(u, zh: false), '71.5K/200K (35.8%)');
    expect(contextUsageSummary(u, zh: true), '7.2万/20万 (35.8%)');
  });

  test('token counts use compact notation', () {
    expect(compactCount(999, zh: false), '999');
    expect(compactCount(1000, zh: false), '1K');
    expect(compactCount(999960, zh: false), '1M');
    expect(compactCount(1048576, zh: false, fractionDigits: 0), '1M');
    expect(compactCount(9999, zh: true), '9999');
    expect(compactCount(1000000, zh: true, fractionDigits: 0), '100万');
    expect(groupedCount(71505), '71,505');
    expect(groupedCount(200), '200');
    expect(percentText(0.12), '12%');
  });

  testWidgets('context ring opens the context card', (tester) async {
    await tester.pumpWidget(host(Composer(
      hint: 'hint',
      onSend: (_, __) async => true,
      contextUsage: const ContextUsage(
        used: 50000,
        size: 200000,
        breakdown: [ContextSource('messages', 3, 0.75), ContextSource('system_prompt', 1, 0.25)],
      ),
    )));
    expect(find.byType(ContextRing), findsOneWidget);

    await tester.tap(find.byType(ContextRing));
    await tester.pumpAndSettle();
    expect(find.text('Context windows'), findsOneWidget);
    expect(find.text('50K/200K (25%)'), findsOneWidget);
    expect(find.text('Messages'), findsOneWidget);
    expect(find.text('75%'), findsOneWidget);
    // The filled segments keep the bar's height.
    final segment = find.descendant(of: find.byType(ContextUsageCard), matching: find.byType(ColoredBox)).last;
    expect(tester.getSize(segment).height, 8);
    // No cache hit rate reported.
    expect(find.text('Average cache hit rate'), findsNothing);

    // Compressing lives in the task menu, not in the card.
    expect(find.text('Compress'), findsNothing);
  });

  testWidgets('the input box can be the context bar instead of the ring', (tester) async {
    await tester.pumpWidget(ContextDisplayScope(
      display: ContextDisplay.bar,
      child: host(Composer(
        hint: 'hint',
        onSend: (_, __) async => true,
        contextUsage: const ContextUsage(used: 50000, size: 200000),
      )),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(ContextRing), findsNothing);
    final box =
        tester.widget<Container>(find.ancestor(of: find.byType(TextField), matching: find.byType(Container)).first);
    final gradient = (box.decoration! as BoxDecoration).gradient! as LinearGradient;
    expect(gradient.stops, [0, 0.25, 0.25, 1]);

    // Nothing else repeats the context in the toolbar.
    expect(find.text('25%'), findsNothing);
  });

  testWidgets('quotas leave the ring when the header shows them', (tester) async {
    Widget composer(QuotaPlacement quotas) => ContextDisplayScope(
          display: ContextDisplay.ring,
          quotas: quotas,
          child: host(Composer(
            hint: 'hint',
            onSend: (_, __) async => true,
            model: const ModelSelection('account:bigmodel-individual-coding-plan', 'GLM-5.3'),
            planUsage: PlanUsageStore(() => null),
            contextUsage: const ContextUsage(used: 50000, size: 200000),
          )),
        );
    await tester.pumpWidget(composer(QuotaPlacement.ring));
    expect(tester.widget<ContextRing>(find.byType(ContextRing)).rings, isNotNull);
    await tester.pumpWidget(composer(QuotaPlacement.header));
    expect(tester.widget<ContextRing>(find.byType(ContextRing)).rings, isNull);
  });

  testWidgets('glass frosts the composer and the sheets', (tester) async {
    Widget composer(bool glass) => GlassScope(
          enabled: glass,
          child: host(Composer(
            hint: 'hint',
            onSend: (_, __) async => true,
            reasoningLevels: const ['low', 'high'],
            reasoning: 'high',
            onReasoning: (_) {},
          )),
        );
    await tester.pumpWidget(composer(false));
    expect(find.byType(BackdropFilter), findsNothing);

    await tester.pumpWidget(composer(true));
    expect(find.byType(BackdropFilter), findsOneWidget);
    final card =
        tester.widget<Container>(find.descendant(of: find.byType(Glass), matching: find.byType(Container)).first);
    final decoration = card.decoration! as BoxDecoration;
    expect(decoration.color!.a, lessThan(1));
    expect(decoration.boxShadow, isNull);

    // The reasoning sheet is frosted too.
    await tester.tap(find.byType(ThoughtMeter));
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNWidgets(2));
  });

  test('context bar warns when the window is nearly full', () {
    final z = buildZTheme(Brightness.light).extension<ZTokens>()!;
    expect(contextBarGradient(z, 0.5).colors.first, isNot(contextBarGradient(z, 0.95).colors.first));
    expect(contextBarGradient(z, 0.5).colors.last, z.card);
  });

  testWidgets('no ring before the session reports a context window', (tester) async {
    await tester.pumpWidget(host(Composer(hint: 'hint', onSend: (_, __) async => true)));
    expect(find.byType(ContextRing), findsNothing);
  });

  testWidgets('reasoning bar opens a slider that applies the chosen level', (tester) async {
    final picked = <String>[];
    await tester.pumpWidget(host(Composer(
      hint: 'hint',
      onSend: (_, __) async => true,
      reasoningLevels: const ['low', 'high', 'max'],
      reasoning: 'max',
      onReasoning: picked.add,
    )));
    // Only the bar, no label, in the toolbar.
    expect(find.text('Max'), findsNothing);
    await tester.tap(find.byType(ThoughtMeter));
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsOneWidget);
    expect(find.text('Max'), findsOneWidget); // the stop label

    await tester.tap(find.text('Low'));
    await tester.pumpAndSettle();
    expect(picked, ['low']);

    // Dragging to the left end settles on the lowest level too.
    await tester.drag(find.byType(Slider), const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(picked.last, 'low');
  });
}
