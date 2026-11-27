import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:droves/src/model/app_state.dart';
import 'package:droves/src/theme/tokens.dart';

import 'package:droves/src/ui/common/state_message.dart';

/// one shell per test so the bridge down state can see a saved endpoint
Widget frame(Widget child, {String url = ''}) {
  final app = AppState();
  if (url.isNotEmpty) {
    app.endpoints = [Endpoint(url: url, token: 't', label: 'box')];
  }
  return AppScope(
    state: app,
    child: MaterialApp(theme: drovesTheme(Brightness.light), home: child),
  );
}

void main() {
  testWidgets('loading names what it is reading, not just a skeleton', (
    tester,
  ) async {
    await tester.pumpWidget(
      frame(
        Scaffold(
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
      frame(
        Scaffold(
          body: ScreenState(
            loading: false,
            error: 'BridgeError: Connection closed',
            connected: false,
            empty: true,
            subject: 'Scout',
            emptyHeadline: 'Nothing here',
            emptyBody: '',
            onRetry: () {},
          ),
        ),
        url: 'https://box.ts.net:13031/',
      ),
    );
    expect(find.text('Bridge is not connected'), findsOneWidget);
    expect(find.textContaining('closed the connection'), findsOneWidget);
    expect(find.textContaining('ClientException'), findsNothing);
  });

  testWidgets('a stuck loader yields to the disconnected message', (
    tester,
  ) async {
    await tester.pumpWidget(
      frame(
        Scaffold(
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
    expect(find.text('Add bridge'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('Reading from the bridge'), findsNothing);
  });

  testWidgets('error names the subject and keeps retry', (tester) async {
    await tester.pumpWidget(
      frame(
        Scaffold(
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
        url: 'https://box.ts.net:13031/',
      ),
    );
    expect(find.text('Could not read agents'), findsOneWidget);
    expect(find.textContaining('took too long to answer'), findsOneWidget);
    expect(find.text('timeout'), findsNothing);
    expect(find.text('Try again'), findsOneWidget);
  });
}
