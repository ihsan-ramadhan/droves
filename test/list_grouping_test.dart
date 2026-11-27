import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:droves/src/bridge/bridge.dart';
import 'package:droves/src/model/app_state.dart';
import 'package:droves/src/theme/tokens.dart';
import 'package:droves/src/ui/agents_screen.dart';
import 'package:droves/src/ui/inbox_screen.dart';

class _MixedBridge extends Bridge {
  _MixedBridge() : super(Uri.parse('http://127.0.0.1:1'));

  @override
  BridgeState get state => BridgeState.ready;

  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
    Duration timeout = const Duration(seconds: 20),
  ]) async {
    if (method == 'workspace.list') {
      return {
        'workspaces': [
          _workspace('idle', 'idle box', 3),
          _workspace('done', 'done box', 2),
          _workspace('working', 'working box', 1),
          _workspace('blocked', 'blocked box', 0),
        ],
      };
    }
    if (method == 'agent.list') {
      return {
        'agents': [
          for (final (i, (status, workspace)) in [
            ('idle', 'w3'),
            ('done', 'w2'),
            ('working', 'w1'),
            ('blocked', 'w0'),
          ].indexed)
            {
              'pane_id': 'p$i',
              'terminal_id': 't$i',
              'workspace_id': workspace,
              'tab_id': 'tab',
              'agent_status': status,
              'agent': 'omp',
              'cwd': '/tmp',
              'title': 'agent $status',
              'focused': false,
            },
        ],
      };
    }
    return {};
  }

  static Map<String, dynamic> _workspace(
    String status,
    String label,
    int number,
  ) => {
    'workspace_id': 'w$number',
    'label': label,
    'number': number,
    'pane_count': 1,
    'tab_count': 1,
    'agent_status': status,
  };
}

Widget _host(Bridge bridge, Widget child) => AppScope(
  state: AppState()..bridge = bridge,
  child: MaterialApp(theme: drovesTheme(Brightness.light), home: child),
);

double _y(WidgetTester tester, String text) =>
    tester.getTopLeft(find.text(text)).dy;

void main() {
  testWidgets('inbox bands working first, then done, then idle', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_MixedBridge(), const InboxScreen()));
    await tester.pumpAndSettle();

    expect(find.text('WORKING · 2'), findsOneWidget);
    expect(find.text('DONE · 1'), findsOneWidget);
    expect(find.text('IDLE · 1'), findsOneWidget);
    expect(_y(tester, 'WORKING · 2'), lessThan(_y(tester, 'DONE · 1')));
    expect(_y(tester, 'DONE · 1'), lessThan(_y(tester, 'IDLE · 1')));
    expect(_y(tester, 'blocked box'), lessThan(_y(tester, 'working box')));
  });

  testWidgets('agents bands working first, then done, then idle', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_MixedBridge(), const AgentsScreen()));
    await tester.pumpAndSettle();

    expect(find.text('WORKING · 2'), findsOneWidget);
    expect(find.text('DONE · 1'), findsOneWidget);
    expect(find.text('IDLE · 1'), findsOneWidget);
    expect(_y(tester, 'WORKING · 2'), lessThan(_y(tester, 'DONE · 1')));
    expect(_y(tester, 'DONE · 1'), lessThan(_y(tester, 'IDLE · 1')));
    expect(_y(tester, 'blocked box'), lessThan(_y(tester, 'working box')));
  });
}
