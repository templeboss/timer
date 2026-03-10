import 'package:flutter_test/flutter_test.dart';
import 'package:timer_app/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const TimerApp());
    expect(find.text('Work Timer'), findsOneWidget);
  });
}
