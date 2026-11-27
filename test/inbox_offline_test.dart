import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:droves/src/bridge/bridge.dart';
import 'package:droves/src/model/app_state.dart';
import 'package:droves/src/theme/tokens.dart';
import 'package:droves/src/ui/inbox_screen.dart';

void main() {
  testWidgets('inbox keeps one layout while the bridge is not ready', (
    tester,
  ) async {
    final url = Uri.parse('https://box.ts.net:13031/');
    final app = AppState()
      ..endpoints = [Endpoint(url: url.toString(), token: 't')]
      ..bridge = Bridge(url);

    await tester.pumpWidget(
      AppScope(
        state: app,
        child: MaterialApp(
          theme: drovesTheme(Brightness.light),
          home: const InboxScreen(),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Bridge is not connected'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    // the list scaffold would mean the body swaps layout on the next retry
    expect(find.text('Inbox'), findsNothing);
    expect(find.text('Droves'), findsOneWidget);
  });
}
