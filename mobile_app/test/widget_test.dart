import 'package:flutter_test/flutter_test.dart';
import 'package:pantry_mobile/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('Stockd app shell shows its main destinations', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const MyApp());
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Stockd'), findsWidgets);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Inventory'), findsOneWidget);
    expect(find.text('Shopping'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  });
}
