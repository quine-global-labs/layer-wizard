import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:layer_wizard/main.dart';

void main() {
  testWidgets('app boots without crashing', (WidgetTester tester) async {
    // Startup kicks off real async work (reading a file, running
    // `rpm-ostree status`, opening the history DB) behind a
    // CircularProgressIndicator that never "settles" within this test, so
    // this only checks the initial loading frame renders without throwing.
    // runAsync is required because that startup work includes real
    // dart:io Process/FFI calls — without it, flutter_test's fake-time zone
    // flags a dangling Timer from the real I/O once the tree is disposed.
    await tester.runAsync(() async {
      await tester.pumpWidget(const LayerWizardApp());
      await tester.pump();
    });

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
