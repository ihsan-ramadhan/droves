import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:droves/src/bridge/bridge.dart';
import 'package:droves/src/model/app_state.dart';
import 'package:droves/src/theme/tokens.dart';
import 'package:droves/src/ui/chat_screen.dart';

void main() {
  testWidgets('interrupt sits left of send in the composer', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1290, 2790);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final state = AppState()..bridge = Bridge(Uri.parse('http://127.0.0.1:1'));
    await tester.pumpWidget(
      AppScope(
        state: state,
        child: MaterialApp(
          theme: drovesTheme(Brightness.light),
          home: ChatScreen(
            label: 'workspace',
            pane: PaneInfo(
              paneId: 'w1:p1',
              terminalId: 't1',
              workspaceId: 'w1',
              tabId: 'tab1',
              agentStatus: 'idle',
              agent: 'omp',
              cwd: '/tmp',
              title: 'chat',
              focused: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final stop = find.byTooltip('Interrupt (Esc)');
    final send = find.byTooltip('Send');
    expect(stop, findsOneWidget);
    expect(send, findsOneWidget);
    expect(tester.getCenter(stop).dx, lessThan(tester.getCenter(send).dx));
    expect(
      (tester.getCenter(stop).dy - tester.getCenter(send).dy).abs(),
      lessThan(3),
    );

    await tester.pumpWidget(const SizedBox());
  });
}
