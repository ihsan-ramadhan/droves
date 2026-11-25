import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:droves/src/theme/tokens.dart';
import 'package:droves/src/ui/widgets.dart';

void main() {
  testWidgets('loading names what it is reading, not just a skeleton', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: drovesTheme(Brightness.light),
        home: Scaffold(
          body: ScreenState(
            loading: true,
            error: null,
            connected: true,
            empty: false,
            subject: 'Scout',
            emptyHeadline: 'Nothing here',
            emptyBody: '',
            onRetry: () {},
          ),
        ),
      ),
    );
    expect(
      find.textContaining('Reading from the bridge Scout'),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('disconnected outranks a stale error', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: drovesTheme(Brightness.light),
        home: Scaffold(
          body: ScreenState(
            loading: false,
            error: 'Connection closed',
            connected: false,
            empty: true,
            subject: 'Scout',
            emptyHeadline: 'Nothing here',
            emptyBody: '',
            onRetry: () {},
          ),
        ),
      ),
    );
    expect(find.text('Bridge is not connected'), findsOneWidget);
    expect(find.text('Connection closed'), findsNothing);
  });

  testWidgets('a stuck loader yields to the disconnected message', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: drovesTheme(Brightness.light),
        home: Scaffold(
          body: ScreenState(
            loading: true,
            error: null,
            connected: false,
            empty: true,
            subject: 'Scout',
            emptyHeadline: 'Nothing here',
            emptyBody: '',
            onRetry: () {},
          ),
        ),
      ),
    );
    expect(find.text('Bridge is not connected'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('Reading from the bridge'), findsNothing);
  });

  testWidgets('error names the subject and keeps retry', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: drovesTheme(Brightness.light),
        home: Scaffold(
          body: ScreenState(
            loading: false,
            error: 'timeout',
            connected: true,
            empty: false,
            subject: 'agents',
            emptyHeadline: 'Nothing here',
            emptyBody: '',
            onRetry: () {},
          ),
        ),
      ),
    );
    expect(find.text('Could not read agents'), findsOneWidget);
    expect(find.text('timeout'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });
}
