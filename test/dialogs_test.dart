import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:droves/src/theme/tokens.dart';
import 'package:droves/src/ui/dialogs.dart';

Widget host(
  Future<Object?> Function(BuildContext) open,
  void Function(Object?) sink,
) {
  return MaterialApp(
    theme: drovesTheme(Brightness.light),
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async => sink(await open(context)),
          child: const Text('open'),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('confirm returns true only on the confirm label', (tester) async {
    Object? result;
    await tester.pumpWidget(
      host(
        (context) => confirmDialog(
          context,
          title: 'Push this branch?',
          body: 'Commits leave this machine only when you confirm.',
          confirmLabel: 'Push',
        ),
        (v) => result = v,
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Push this branch?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isFalse);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Push'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('prompt returns the trimmed text', (tester) async {
    Object? result;
    await tester.pumpWidget(
      host(
        (context) => promptText(
          context,
          title: 'Rename tab',
          hint: 'Label',
          confirmLabel: 'Save',
          initial: 'old ',
        ),
        (v) => result = v,
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  build  ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result, 'build');
  });

  testWidgets('a dismissed prompt reads as null', (tester) async {
    Object? result = 'unset';
    await tester.pumpWidget(
      host(
        (context) => promptText(
          context,
          title: 'New file',
          hint: 'notes.md',
          confirmLabel: 'Create',
        ),
        (v) => result = v,
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
}
