import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/desktop/widgets/g3_legal_notices.dart';

void main() {
  testWidgets('legal notices are available on demand and fit a narrow client',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: G3LegalNotices(license: 'GNU AGPL v3', year: 2026)))));
    expect(find.text('Rechtliche Hinweise / Legal notices'), findsOneWidget);
    expect(find.textContaining('Purslane'), findsNothing);
    await tester.tap(find.text('Rechtliche Hinweise / Legal notices'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Copyright © 2026 Purslane Tech Pte. Ltd.'),
        findsOneWidget);
    expect(find.text('Lizenztext / License'), findsOneWidget);
    expect(find.text('Quellcode / Source code'), findsOneWidget);
    expect(find.textContaining('No warranty'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Rechtliche Hinweise / Legal notices'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Purslane'), findsNothing);
  });
}
