import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:droves/src/bridge/bridge.dart';
import 'package:droves/src/model/app_state.dart';
import 'package:droves/src/theme/tokens.dart';
import 'package:droves/src/ui/chat_screen.dart';

class _WorkingBridge extends Bridge {
  _WorkingBridge() : super(Uri.parse('http://127.0.0.1:1'));

  final interrupts = <String>[];

  @override
  BridgeState get state => BridgeState.ready;

  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
    Duration timeout = const Duration(seconds: 20),
  ]) async {
    if (method == 'pane.list') {
      return {
        'panes': [
          {
            'pane_id': 'w1:p1',
            'terminal_id': 't1',
            'workspace_id': 'w1',
            'tab_id': 'tab1',
            'agent_status': 'working',
            'agent': 'omp',
            'cwd': '/tmp',
            'title': 'chat',
            'focused': true,
          },
        ],
      };
    }
    return {};
  }

  @override
  Future<void> sendText(String paneId, String text) async {
    interrupts.add('$paneId:$text');
  }
}

void main() {
  testWidgets('composer shows a single send action', (tester) async {
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

    // the send button occupies the trailing slot; interrupt reuses the same
    // slot while the agent works (no second standalone stop button)
    expect(find.byTooltip('Send'), findsOneWidget);
    expect(find.byTooltip('Interrupt (Esc)'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('composer swaps send for interrupt while the agent works', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1290, 2790);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final bridge = _WorkingBridge();
    final state = AppState()..bridge = bridge;
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
              agentStatus: 'working',
              agent: 'omp',
              cwd: '/tmp',
              title: 'chat',
              focused: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Interrupt (Esc)'), findsOneWidget);
    expect(find.byTooltip('Send'), findsNothing);

    await tester.tap(find.byTooltip('Interrupt (Esc)'));
    await tester.pump();
    expect(bridge.interrupts, ['w1:p1:\x1b']);

    await tester.pumpWidget(const SizedBox());
  });
}
