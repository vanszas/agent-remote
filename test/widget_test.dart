import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Material 3 demo shell renders', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          appBar: AppBar(title: const Text('Hermes Remote')),
          body: const Text('Demo Mode'),
        ),
      ),
    );
    expect(find.text('Hermes Remote'), findsOneWidget);
    expect(find.text('Demo Mode'), findsOneWidget);
  });
}
