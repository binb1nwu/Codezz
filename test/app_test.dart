import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:codezz/main.dart';
import 'package:codezz/state/app_state.dart';

void main() {
  testWidgets('first launch shows the add-device empty state', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final app = AppState();
    await tester.runAsync(app.init);
    await tester.pumpWidget(CodezzApp(app: app));
    await tester.pumpAndSettle();
    expect(find.text('No devices yet'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Add device'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Add device'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'https://zcode.z.ai/remote/v4?sid=a&hash=b');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('The remote link is incomplete'), findsOneWidget);
    app.dispose();
  });
}
