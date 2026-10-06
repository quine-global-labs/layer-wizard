import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:layer_wizard/main.dart';

void main() {
  testWidgets('app boots without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(const LayerWizardApp());
    // Intentionally a single pump, not pumpAndSettle: startup kicks off real
    // async work (reading a file, running `rpm-ostree status`) behind a
    // CircularProgressIndicator, which never "settles". This just checks
    // the app renders its initial loading frame without throwing.
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
